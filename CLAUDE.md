# azure-aks-cluster

Hello-world container on AKS, scheduled on a Virtual Node (ACI-backed — the AKS homolog of an EKS Fargate profile), exposed via AGIC with a Let's Encrypt cert, image in a dedicated ACR, monitored via Container Insights into an existing Log Analytics Workspace. Also hosts Argo CD (Helm, `argocd` namespace), mirroring its role in `aws-eks-cluster`.

## Por que este cluster no puede ser 100% serverless (a diferencia de EKS)

EKS corre 100% en Fargate, sin ningun node group. AKS no puede replicar eso: `default_node_pool`
es un bloque obligatorio de `azurerm_kubernetes_cluster`, y varios componentes necesitan
`hostNetwork`/acceso al host que Virtual Nodes (ACI) no provee - CoreDNS, kube-proxy, Azure CNS, el
addon de AGIC y el propio ACI connector que habilita Virtual Nodes. La paridad real alcanzable es:
toda *carga de trabajo* (hello-world, los 8 componentes de Argo CD) corre en Virtual Nodes; el node
pool real queda dedicado exclusivamente a esos componentes de sistema, sin excepciones.

## Argo CD en Virtual Nodes, no en el node pool real - y por que no hacia falta pedir mas cuota

La cuota regional de este subscription es de 4 vCPU **totales**, ya consumidos enteros por los 2
nodos reales existentes (`variables.tf`) - un tercer nodo (o VMs mas grandes) hubiera requerido
pedir un aumento de cuota a Azure antes de poder aplicar nada. Los cores de ACI son una cuota
**separada** de la de VMs, asi que los ~1.4 vCPU / ~2.3 GB que consume Argo CD corren por completo
fuera de ese techo - el node pool real no se toca.

Verificado contra el chart real (`argo/argo-cd` 10.8.2, el mismo pin que usa `aws-eks-cluster`)
antes de asumir que esto funcionaba:
- `global.nodeSelector`/`global.tolerations` llegan a los 8 pod templates del chart (6 Deployment,
  1 StatefulSet `argocd-application-controller`, 1 Job `argocd-redis-secret-init`) - confirmado
  renderizando el chart, no leido de la doc.
- ACI no tiene overcommit (mismo gotcha que ya documentaba este archivo para hello-world) -
  `resources.requests` debe ser identico a `resources.limits` en los 8 workloads. El chart no fija
  ninguno por default - hay que declararlos los 8, ver `argocd/values.yaml`.
- Los `initContainers` (ej. `copyutil` en varios de los Deployments, que copia el binario de argocd
  a un volumen compartido) heredan el `resources` del componente padre en este chart - confirmado
  renderizando, no asumido. Si no fuera asi, ACI rechazaria el pod igual por el mismo motivo de
  arriba, solo que en un container distinto al que uno mira primero.
- Los unicos tipos de volumen que usa el chart son `configMap`/`emptyDir`/`secret` - nada de PVC ni
  `hostPath`, compatible con Virtual Nodes sin ningun cambio adicional.

Sizing de `argocd/values.yaml` es un punto de partida (controller 500m/1Gi, repoServer 250m/512Mi,
resto 100m/128Mi) - ajustar contra OOMKills o CPU throttling reales una vez desplegado, mismo
criterio que el resto de este repo ("encontrado empiricamente, no leido de la doc" - ver mas abajo).

## Segundo certificado + segundo host, mismo Application Gateway

AGIC soporta multiples Ingress sobre un mismo Application Gateway de forma nativa (multi-site,
por host) - a diferencia de un ALB de AWS, no hace falta nada equivalente a
`alb.ingress.kubernetes.io/group.name`. `argocd.azure.jalcalaroot.com` comparte el mismo
`azurerm_public_ip.appgw` que `aks.azure.jalcalaroot.com`, cada uno con su propio
`acme_certificate` (recursos separados, no un `for_each`, para no arriesgar el cert de hello-world
que ya esta en uso - mismo criterio que tomo `aws-eks-cluster/acm.tf`) y su propio K8s TLS Secret
(`argocd-server-tls`, nombre que fija el chart cuando `server.ingress.tls: true`).

## `server.insecure: true` en Argo CD - mismo motivo que en EKS

AGIC termina TLS en el gateway (el Ingress de `argocd-server` referencia el TLS Secret). Si el
backend de Argo tambien sirve HTTPS (su default), queda un mismatch/redirect loop. `insecure` hace
que el pod sirva HTTP plano puertas adentro - mismo patron que usa `aws-eks-cluster` con el ALB.

## Application Gateway no tiene ningun certificado gratis/administrado - a diferencia del ALB de AWS

Verificado contra la doc oficial de Microsoft (no asumido): *"Application gateway doesn't provide
any capability to create a new certificate or send a certificate request to a certification
authority"* - hay que traer el certificado propio siempre (PFX subido a mano, o referenciado desde
Key Vault). Azure si tiene certificados gratis administrados, pero en otros dos productos, ninguno
aplicable aca:
- **App Service** - certificado gratis real (DigiCert, auto-renovado), pero solo para dominios
  custom de App Service.
- **Front Door Standard/Premium** - certificados administrados por Microsoft, pero incluidos dentro
  de la tarifa del servicio (Standard arranca ~US$35/mes, Premium ~US$330/mes) - "gratis" solo si ya
  se esta pagando Front Door, que no es este proyecto.

Esta es una asimetria real entre las dos nubes, no una decision de diseno de este repo: en AWS, ACM
es gratis y se conecta directo al ALB (ver `aws-eks-cluster/acm.tf`) - ahi Let's Encrypt seria
redundante. En Azure, para Application Gateway especificamente, Let's Encrypt (`acme.tf`) no es un
atajo barato - es la **unica** opcion gratuita que existe, porque Azure no le dio esa capacidad a
este servicio en particular. Si el dia de mañana este proyecto migrara a Front Door en vez de
Application Gateway "bring your own", recien ahi tendria sentido evaluar sacar `acme.tf` a favor de
un certificado administrado por Microsoft - hoy no aplica.

## Costo real de Argo CD idle, no solo el de hello-world

7 de los 8 componentes corren 24/7 en ACI (el octavo, `redisSecretInit`, es un Job de una sola
corrida que no queda residente) - a los tamanos de `argocd/values.yaml` suman ~1.4 vCPU /
~2.3 GB combinados - del orden de US$50-60/mes solo por tener Argo CD prendido sin sincronizar
nada todavia. `dex` (SSO, sin usar hoy) y `notifications` (sin canales configurados) son ~US$8/mes
de eso - se dejan prendidos por paridad 1:1 con `aws-eks-cluster`, pero el dato queda escrito para
la proxima vez que se revise el costo del proyecto.

## KEDA instalado (2026-09-12) - Virtual Nodes, sin cambios de Terraform

Mismo mecanismo de scheduling que Argo CD (`global`... en este chart, `nodeSelector`/`tolerations`
de nivel superior, ver `keda/values.yaml`) y misma razon: la cuota regional de 4 vCPU no se toca
porque ACI es una cuota separada. A diferencia de Argo CD, esta vez no hizo falta ningun cambio de
Terraform (sin DNS, sin certificado, sin Ingress) - KEDA es un operator + un metrics-adapter para
`external.metrics.k8s.io`, sin UI ni endpoint publico.

Verificado contra el chart real (`kedacore/keda` 2.20.2) antes de asumirlo:
- Solo 3 Deployments (`keda-operator`, `keda-operator-metrics-apiserver`,
  `keda-admission-webhooks`), sin Job ni StatefulSet - mas simple que Argo CD.
- El chart SI trae `resources` por default, pero `requests` (100m/100Mi) != `limits` (1/1000Mi) en
  los 3 - misma exigencia de ACI que ya documenta este archivo para Argo CD, hubo que igualarlos.
  Las rutas correctas no estan anidadas dentro de cada seccion de componente como parecería -
  son un bloque separado `resources.operator` / `resources.metricServer` (sin "s") /
  `resources.webhooks`, confirmado renderizando antes de escribir `keda/values.yaml`.
- El certificado del webhook de validacion lo genera y rota el propio `keda-operator` (RBAC propio
  sobre el secret `kedaorg-certs`) - sin cert-manager, y el unico volumen que usa es `secret`, sin
  PVC ni hostPath, compatible con Virtual Nodes sin ningun ajuste adicional.

Instalado como infraestructura base, sin ningun `ScaledObject`/`ScaledJob` configurado todavia - no
hay ninguna app con carga variable real corriendo hoy que justifique uno.

## Design decisions worth knowing before changing anything

- **Virtual Nodes requires Azure CNI flat networking, not Overlay.** Confirmed against Microsoft's own docs ("use overlay when you don't need advanced features such as virtual nodes"). `aks.tf`'s `network_profile` deliberately omits `network_plugin_mode = "overlay"` and `pod_cidr` — every pod (real node and Virtual Nodes both) gets a real, routable VNet IP. This is why `snet-aks-virtual-nodes` (added in `jalcalaroot-azure-bootstrap`) is a full `/24`, not a small overlay-style tier.
- **Two separate subnets, both required.** `snet-aks` (real node pool) and `snet-aks-virtual-nodes` (delegated to `Microsoft.ContainerInstance/containerGroups`, for the ACI-backed pods) can't be the same subnet — Virtual Nodes needs its own dedicated, delegated subnet by design.
- **No Key Vault.** Unlike `azure-container-apps`, AGIC doesn't read TLS certs from Key Vault — it reads a Kubernetes `Secret` referenced in the `Ingress` resource. The ACME certificate is exposed as sensitive Terraform outputs (`certificate_pem`, `certificate_private_key_pem`) and turned into a K8s Secret via a documented manual `kubectl create secret tls` step.
- **`acme_certificate` needs `common_name`, not `certificate_request_pem`.** Same gotcha as `azure-container-apps`: `certificate_pem`/`private_key_pem` only come back populated when the resource generates its own key from `common_name` — an external CSR leaves them empty.
- **Application Gateway is "bring your own," with a placeholder config.** Terraform requires at least one valid `backend_address_pool`/`http_listener`/`request_routing_rule` to create the resource at all — these are throwaway placeholders that AGIC overwrites the moment the first `Ingress` is applied. `lifecycle.ignore_changes` on `azurerm_application_gateway.this` covers every block AGIC touches, so subsequent `terraform apply` runs don't fight AGIC's live changes and try to revert them.
- **`only_critical_addons_enabled` must stay unset on the default node pool.** Setting it is a known way to break AGIC — the AGIC pod is classified as a "non-critical addon" and fails to start if that flag is on. Don't add it as a "hardening" measure without re-checking this.
- **`node_provisioning_profile { mode = "Manual" }` is required by azurerm >= 5.x**, even though we don't use Node Autoprovisioning here — the provider errors at plan time without at least one `node_provisioning_profile` block present.
- **Kubernetes manifests (`k8s/*.yaml`) are applied manually via `kubectl`, not Terraform-managed.** Consistent with how `azure-container-apps` treats the Docker image build/push — Terraform's job is the infra, not the app deployment. The `<ACR_LOGIN_SERVER>` and `<FQDN>` placeholders in the YAML need substituting before `kubectl apply` (see README).
- **The hello-world Deployment needs explicit `nodeSelector` + `tolerations`** (`kubernetes.io/role: agent`, `type: virtual-kubelet`, tolerate `virtual-kubelet.io/provider`) to actually land on the Virtual Node. Without these, the scheduler puts it on the real "system" node like any other pod — Virtual Nodes never claims pods automatically the way it might sound.
- **`aks.tf`'s `network_profile` needs an explicit `service_cidr`/`dns_service_ip` outside the VNet's range.** AKS defaults to `10.0.0.0/16` for the service CIDR, which collided head-on with `vnet-jalcalaroot` (also `10.0.0.0/16`) — `ServiceCidrOverlapExistingSubnetsCidr` at apply time. Set to `172.16.0.0/16` (purely virtual, never routed on the VNet, so any non-overlapping range works).
- **`default_node_pool_vm_size` and `default_node_pool_node_count` are both subscription-quota-constrained, found empirically, not by reading docs first:** `Standard_D2s_v5` isn't in this subscription's allowed SKU list for `eastus` (400 `BadRequest`, full allowed list is v7-generation D/E/F plus a few specialized series) — swapped for `Standard_D2s_v7`. Separately, **total regional vCPU quota is only 4** — not per-SKU, the whole region — so with one 2-vCPU node already running, `node_count` tops out at **2**, not 3+, without requesting an Azure quota increase first (`ErrCode_InsufficientVCPUQuota`).
- **Neither the ACI Connector's nor AGIC's auto-created managed identity gets any RBAC automatically — for either addon.** This contradicts what the docs imply about "bring your own" setups being handled for you — and contradicted, for a while, a comment in this repo's own `aks.tf` that claimed the opposite (fixed once the contradiction with the code three lines below it was noticed). Both failed at runtime until these were added explicitly in `aks.tf`:
  - ACI Connector (`aci_connector_linux.connector_identity`) needs **Network Contributor** on `network_aks_virtual_nodes_subnet_id` — without it, the connector pod crash-loops with `AuthorizationFailed` on `subnets/read` the instant it tries to join a container to the subnet.
  - AGIC (`ingress_application_gateway.ingress_application_gateway_identity`) needs **three** separate grants: `Contributor` on the Application Gateway itself, `Reader` on its resource group, *and* **Network Contributor on `network_appgw_subnet_id`** (join/action) — missing any one produces a different opaque error (`ApplicationGatewayForbidden` for the first two, `ApplicationGatewayInsufficientPermissionOnSubnet` for the third). All three are needed because the subnet and (in a real deployment) the gateway can live in a different resource group than the cluster.
  - RBAC propagation after these role assignments can lag a few minutes — a `kubectl delete pod` restart of the connector/AGIC pod that still shows the old `AuthorizationFailed` error doesn't mean the role assignment is wrong, it may just not have propagated yet. Give it 2-3 minutes and retry before assuming the permission itself is incorrect.
- **Virtual Nodes pods need an explicit image pull secret — the kubelet identity's `AcrPull` role (`acr.tf`) only covers the real node pool.** The ACI Connector creates container groups with no managed identity for registry auth, so pulling from ACR fails with `InaccessibleImage` unless the pod has `imagePullSecrets` pointing at a `docker-registry` secret. Generate scoped, non-expiring credentials with an ACR token (`az acr token create ... --scope-map _repositories_pull`) rather than enabling the ACR admin account — see README step 4.
- **ACI (Virtual Nodes) has no overcommit — `resources.requests` must equal `resources.limits`, exactly, for both cpu and memory.** A pod with `requests: 100m` / `limits: 250m` gets rejected at the Azure API level with `ContainerLimitGreaterThanContainerGroupTotalRequest` the moment the ACI Connector tries to create the container group. `k8s/deployment.yaml` sets both to the same value on purpose.
- **Use `spec.ingressClassName`, never the `kubernetes.io/ingress.class` annotation, to select AGIC.** Setting the annotation to the *IngressClass resource's name* (`azure-application-gateway`) looks right and produces no error or warning from AGIC — it silently never processes the Ingress at all, and AGIC just keeps re-applying its empty default/catch-all config (a `placeholder`/`default*`-named pool, listener, and rule with no hostname and no backend). The only symptom is the site not responding; nothing in AGIC's logs calls out the annotation as wrong. `k8s/ingress.yaml` uses `spec.ingressClassName: azure-application-gateway` instead.

## Backend

Same Azure Blob Storage backend as `azure-container-apps` and `jalcalaroot-azure-bootstrap` (`sttfstatejalcalaroot` in resource group `jalcalaroot`, `use_azuread_auth = true`), different key: `aks-cluster/terraform.tfstate`.

## `subscription_id`

Same gotcha as every other project here: set via `TF_VAR_subscription_id`, not `ARM_SUBSCRIPTION_ID`.

## Let's Encrypt rate limits

`acme_server_url` defaults to production (5 duplicate certs/domain/week). Switch to the [staging directory](https://letsencrypt.org/docs/staging-environment/) while iterating.

## Certificate renewal

Same limitation as `azure-container-apps`: `acme_certificate` only re-issues within 30 days of expiry, and only when `terraform apply` actually runs — nothing here triggers that on a schedule. After a renewal, the Kubernetes Secret needs to be re-created (`kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`) for AGIC to pick up the new cert.

## CI/CD

Two dedicated OIDC identities (`ci_identities.tf`), same pattern as `azure-container-apps`: `aks-cluster-agent` (apply) and `aks-cluster-plan` (read-only). RBAC scoped resource-by-resource, not blanket Contributor over a shared resource group.

- **`Contributor` doesn't include `Microsoft.Authorization/roleAssignments/write`.** The agent needs to create `azurerm_role_assignment.aks_acr_pull` (grants `AcrPull` to the cluster's kubelet identity, in `acr.tf`) - Contributor alone 403s on that. Fixed by granting the agent `Role Based Access Control Administrator` scoped to just the ACR resource (not the whole resource group) - lets it manage role assignments *on that one resource* without broader access. Didn't hit this in `azure-container-apps` because nothing there needed the agent itself to grant a role at apply time.
- **Same Log Analytics Contributor gap as `azure-container-apps`.** `oms_agent` needs the workspace's shared key (`Microsoft.OperationalInsights/workspaces/sharedKeys/action`), excluded from `Reader` on purpose - needs `Log Analytics Contributor`.
- **Same Storage Account Reader gap as `azure-container-apps`.** `Storage Blob Data Contributor` is data-plane only; the `data.azurerm_storage_account.tfstate` block needs a management-plane `Reader` too.
- **The weekly schedule on `terraform-apply.yml` only renews the Let's Encrypt certificate - it does NOT update the cluster.** Unlike `azure-container-apps` (where the cert is read live), here the cert is baked into a Kubernetes Secret a human created once. A renewed cert sitting in Terraform state does nothing until someone re-runs the `kubectl create secret tls` step against the live cluster.
- **Checkov also runs a second time against the resolved plan** ([`jalcalaroot/gha-checkov-plan-scan`](https://github.com/jalcalaroot/gha-checkov-plan-scan)), catching what the static HCL scan can't (data sources, variables with no default). Soft-fail on purpose - verified by hand that `--repo-root-for-plan-enrichment`/`--deep-analysis` don't reliably make the plan scan respect existing `#checkov:skip` comments (known open Checkov bug). Making it blocking would re-flag every already-accepted skip in this file as a new finding.
- **The static (blocking) Checkov step also loads custom IAM/RBAC rules** via [`jalcalaroot/johan-cloud-policies`](https://github.com/jalcalaroot/johan-cloud-policies) (`external_checks_dirs`) - house rules the built-in checks don't cover (today: no `azurerm_role_assignment` grants `Owner`, none is scoped directly to a subscription except a small Policy/Cost Management allowlist). Verified by hand against this repo before connecting it: zero findings, nothing broke.

## Consumers

None — this is a leaf project, nothing else reads its outputs.

## Relationship to the network project

Reads (copied values, no `terraform_remote_state`): `network_aks_subnet_id`, `network_aks_virtual_nodes_subnet_id`, `network_appgw_subnet_id`, `network_log_analytics_workspace_id`. The virtual-nodes subnet doesn't exist in the versioned network module — it was added directly to the consuming environment's root module (same approach as the Container Apps subnet), to avoid bumping that module's version for a project-specific addition.
