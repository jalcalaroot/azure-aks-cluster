# azure-aks-cluster

Hello-world container on AKS, scheduled on a Virtual Node (ACI-backed — the AKS homolog of an EKS Fargate profile), exposed via AGIC with a Let's Encrypt cert, image in a dedicated ACR, monitored via Container Insights into an existing Log Analytics Workspace. Also hosts Argo CD (Helm, `argocd` namespace, real node pool — see below), mirroring its role in `aws-eks-cluster`.

## Por que este cluster no puede ser 100% serverless (a diferencia de EKS)

EKS corre 100% en Fargate, sin ningun node group. AKS no puede replicar eso: `default_node_pool`
es un bloque obligatorio de `azurerm_kubernetes_cluster`, y varios componentes necesitan
`hostNetwork`/acceso al host que Virtual Nodes (ACI) no provee - CoreDNS, kube-proxy, Azure CNS, el
addon de AGIC y el propio ACI connector que habilita Virtual Nodes. hello-world corre en Virtual
Nodes; Argo CD, no (ver abajo) - el node pool real queda dedicado a los componentes de sistema
**mas** Argo CD, no exclusivamente a sistema como se pensaba originalmente.

## Argo CD termino en el node pool real, no en Virtual Nodes (revertido 2026-09-16)

El plan original era Virtual Nodes para los 8 componentes de Argo CD, igual que hello-world, para
no tocar la cuota de VM (ver mas abajo). Se verifico contra el chart renderizado
(`helm template`) antes de asumir que funcionaba: `global.nodeSelector`/`tolerations` llegan a los
8 pod templates, ACI no tiene overcommit (requests debe ser igual a limits, declarado para los 8),
los `initContainers` heredan `resources` del componente padre, los unicos volumenes son
`configMap`/`emptyDir`/`secret` (sin PVC/hostPath). Todo eso resulto correcto - pero **ninguna de
esas verificaciones prueba que ACI pueda arrancar el container en si**, y esa es la parte que fallo
en el primer install real:

> ACI does not support providing args without specifying the command. Please supply both command
> and args to the pod spec.

Casi todo el chart de `argo-cd` declara `args` confiando en el `ENTRYPOINT` de la imagen (el patron
normal en cualquier nodo real) - ACI/virtual-kubelet no soporta eso, exige `command` explicito.
Reescribir `command`+`args` component por component (6 imagenes distintas) para mantenerlos en
Virtual Nodes no es viable de sostener a traves de cada bump de version del chart - se movio todo
`argocd/values.yaml`'s `global.nodeSelector`/`tolerations` al node pool real en su lugar.

Esto **no** necesito pedir mas cuota de VM: la cuota regional (4 vCPU totales, ya consumidos por
los 2 nodos existentes - ver `variables.tf`) rige la creacion de VMs nuevas o mas grandes, no
cuantos pods corren en una VM ya existente. Los ~1.4 vCPU / ~2.3 GB combinados de los 7 workloads
de Argo CD (el Job `argocd-redis-secret-init` corre y termina antes de que el resto del release se
cree) entran sin problema en la capacidad ya disponible de los 2 nodos `Standard_D2s_v7`.

Otro gap real encontrado en el mismo install: el ACI connector de este cluster convierte memoria a
GB truncando a 1 decimal (bug de precision del connector, no de este repo) - un `redisSecretInit`
con 64Mi (0.0625GB) truncaba a 0.0 y Azure lo rechazaba con `ResourceNegativeOrZero` al crear el
container group. Quedo en 256Mi en `argocd/values.yaml` (con margen), aunque ya no corra en ACI -
no hace dano dejarlo así.

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

**Actualización (2026-09-16) - se movio al node pool real**: al redesplegar el cluster desde cero
esta vez, el primer `helm install` fue un install liso (sin `keda/values.yaml`, mientras se
resolvian otros errores mas urgentes) - termino en el node pool real por default, no en Virtual
Nodes. En vez de revertirlo a Virtual Nodes para calzar con este archivo, se hizo lo opuesto:
se actualizo `keda/values.yaml` (`nodeSelector: kubernetes.io/os: linux`, sin tolerations) para que
la IaC describa lo que en efecto corre. Motivo real, no solo prolijidad: durante el mismo redeploy
se confirmo que **metrics-server nunca devuelve metricas de ningun pod en Virtual Nodes**
(`kubectl get --raw /apis/metrics.k8s.io/v1beta1/...` no encuentra el pod, repetido varias veces
contra distintas apps - ver `k8s-apps/CLAUDE.md` para el detalle completo) - el trigger `cpu` de
KEDA depende 100% de esa API. Correr el propio KEDA en Virtual Nodes no arregla eso (el problema
es de los pods *objetivo*, no del operator), pero sumarlo ahi de todas formas seria una segunda
superficie de riesgo de scheduling sin ningun beneficio real - se prefirio colocarlo junto a Argo
CD en el node pool real.

`helm upgrade keda kedacore/keda --version 2.20.2 -n keda -f keda/values.yaml` aplicado contra el
cluster real para que el Helm release en si tambien calce con este archivo (no solo quedo
documentado, se verifico con los 3 pods `Running` en el node pool real despues).

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
- **The static (blocking) Checkov step also loads custom IAM/RBAC rules** via [`jalcalaroot/johan-cloud-policies`](https://github.com/jalcalaroot/johan-cloud-policies) (`external_checks_dirs`) - house rules the built-in checks don't cover: no `azurerm_role_assignment` grants `Owner`/`User Access Administrator`/`Role Based Access Control Administrator` (`Contributor` deliberately excluded - it can't grant access to anyone), none is scoped directly to a subscription except a small Policy/Cost Management allowlist, and every taggable resource has `Owner`/`Environment` tags. `ci_agent_acr_rbac_admin` above trips the privileged-role check on purpose - it's real RBAC Administrator, just scoped to one resource - and carries an inline `#checkov:skip` with this same justification. The plan-scan step (below) also loads `custom_policies/plan_only/azure` - a management-group-scope check that only evaluates correctly against a resolved plan, not static HCL (verified by hand: the static scan sees the unresolved `scope` reference, never the ARM ID).
- **This repo's tags used to be in Spanish** (`ambiente`/`propietario`/`proyecto`) while the rest of the account uses English - renamed to `Environment`/`Owner`/`Project` (2026-09-15) so the tag check above could actually verify what was already there, instead of false-flagging it as untagged.

## Cluster destroyed: CI stays broken until redeploy (found 2026-09-15)

`aks-cluster-agent`/`aks-cluster-plan` (`ci_identities.tf`) live in the **same** Terraform state as the cluster. When the cluster is torn down to avoid paying while idle, those two identities go with it - confirmed with `az identity list`/`az ad app show`: neither `aks-cluster-ci-plan` nor its underlying app registration exist right now.

Consequence: **every PR's CI stays red** until someone redeploys - Azure login fails with `AADSTS700016: Application ... was not found in the directory`, because the identity GitHub Actions tries to authenticate as doesn't exist. Confirmed this isn't new: the last few Dependabot PRs before this was found already failed the same way, same step.

Same bootstrapping trap as `aws-eks-cluster`, distinct from `jalcalaroot-azure-bootstrap` (that repo's CI identities live in their own persistent state, so it can keep planning even with the network/cluster torn down). Not fixed here - to plan against this repo again, the identities (or the whole cluster) need to be recreated with broad local credentials first, not via the pipeline. Documented for whenever that redeploy happens, not treated as a code bug to fix today.

## Consumers

[`k8s-apps`](https://github.com/jalcalaroot/k8s-apps)'s `Ingress` manifests (`apps/<name>/overlays/aks/ingress.yaml`) reference TLS Secrets (`<app>-tls`) created manually from this repo's `demo_apps_certificate_pem`/`demo_apps_certificate_private_key_pem` outputs — not a `terraform_remote_state` read, same manual-copy pattern as everything else this repo consumes from the network project.

## Las 3 apps demo de k8s-apps ahora tienen URL publica (2026-09-16)

`acme.tf` gano un tercer bloque (`acme_certificate.demo_apps`, `for_each` sobre `podinfo`/`game-2048`/`uptime-kuma`) - mismo patron que hello-world/argocd (misma `acme_registration.this`, mismo `dns_challenge` via `azuredns`), pero con `for_each` en vez de un recurso explicito por app. Comparten el mismo Application Gateway via el multi-site nativo de AGIC - un host mas, no un Application Gateway nuevo.

**A diferencia de AWS, acá no hay validación automática vía Route53** - Terraform emite el cert PEM+key directo (mismo mecanismo que hello-world/argocd), y el TLS Secret de Kubernetes (`<app>-tls`) se crea a mano con `kubectl create secret tls`, igual que `hello-world-tls`/`argocd-server-tls`. El registro DNS (A, no CNAME - Application Gateway tiene IP publica fija, a diferencia del ALB de AWS que usa un DNS name que puede cambiar) tambien se creo a mano vía `az network dns record-set a add-record`.

Mismo aviso que en `aws-eks-cluster/CLAUDE.md`: si un cert se recrea, el TLS Secret hay que regenerarlo a mano - no hay sincronizacion automatica entre este repo y `k8s-apps`.

## Relationship to the network project

Reads (copied values, no `terraform_remote_state`): `network_aks_subnet_id`, `network_aks_virtual_nodes_subnet_id`, `network_appgw_subnet_id`, `network_log_analytics_workspace_id`. The virtual-nodes subnet doesn't exist in the versioned network module — it was added directly to the consuming environment's root module (same approach as the Container Apps subnet), to avoid bumping that module's version for a project-specific addition.
