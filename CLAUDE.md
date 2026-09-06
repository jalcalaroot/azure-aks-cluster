# azure-aks-containers-poc

POC: hello-world container on AKS, scheduled on a Virtual Node (ACI-backed — the AKS homolog of an EKS Fargate profile), exposed via AGIC with a Let's Encrypt cert, image in a dedicated ACR, monitored via Container Insights into an existing Log Analytics Workspace.

## Design decisions worth knowing before changing anything

- **Virtual Nodes requires Azure CNI flat networking, not Overlay.** Confirmed against Microsoft's own docs ("use overlay when you don't need advanced features such as virtual nodes"). `aks.tf`'s `network_profile` deliberately omits `network_plugin_mode = "overlay"` and `pod_cidr` — every pod (real node and Virtual Nodes both) gets a real, routable VNet IP. This is why `snet-aks-virtual-nodes` (added in `jalcalaroot-azure-bootstrap`) is a full `/24`, not a small overlay-style tier.
- **Two separate subnets, both required.** `snet-aks` (real node pool) and `snet-aks-virtual-nodes` (delegated to `Microsoft.ContainerInstance/containerGroups`, for the ACI-backed pods) can't be the same subnet — Virtual Nodes needs its own dedicated, delegated subnet by design.
- **No Key Vault.** Unlike `azure-container-apps-poc`, AGIC doesn't read TLS certs from Key Vault — it reads a Kubernetes `Secret` referenced in the `Ingress` resource. The ACME certificate is exposed as sensitive Terraform outputs (`certificate_pem`, `certificate_private_key_pem`) and turned into a K8s Secret via a documented manual `kubectl create secret tls` step.
- **`acme_certificate` needs `common_name`, not `certificate_request_pem`.** Same gotcha as `azure-container-apps-poc`: `certificate_pem`/`private_key_pem` only come back populated when the resource generates its own key from `common_name` — an external CSR leaves them empty.
- **Application Gateway is "bring your own," with a placeholder config.** Terraform requires at least one valid `backend_address_pool`/`http_listener`/`request_routing_rule` to create the resource at all — these are throwaway placeholders that AGIC overwrites the moment the first `Ingress` is applied. `lifecycle.ignore_changes` on `azurerm_application_gateway.this` covers every block AGIC touches, so subsequent `terraform apply` runs don't fight AGIC's live changes and try to revert them.
- **`only_critical_addons_enabled` must stay unset on the default node pool.** Setting it is a known way to break AGIC — the AGIC pod is classified as a "non-critical addon" and fails to start if that flag is on. Don't add it as a "hardening" measure without re-checking this.
- **`node_provisioning_profile { mode = "Manual" }` is required by azurerm >= 5.x**, even though we don't use Node Autoprovisioning here — the provider errors at plan time without at least one `node_provisioning_profile` block present.
- **Kubernetes manifests (`k8s/*.yaml`) are applied manually via `kubectl`, not Terraform-managed.** Consistent with how `azure-container-apps-poc` treats the Docker image build/push — Terraform's job is the infra, not the app deployment. The `<ACR_LOGIN_SERVER>` and `<FQDN>` placeholders in the YAML need substituting before `kubectl apply` (see README).
- **The hello-world Deployment needs explicit `nodeSelector` + `tolerations`** (`kubernetes.io/role: agent`, `type: virtual-kubelet`, tolerate `virtual-kubelet.io/provider`) to actually land on the Virtual Node. Without these, the scheduler puts it on the real "system" node like any other pod — Virtual Nodes never claims pods automatically the way it might sound.
- **`aci.tf`'s `network_profile` needs an explicit `service_cidr`/`dns_service_ip` outside the VNet's range.** AKS defaults to `10.0.0.0/16` for the service CIDR, which collided head-on with `vnet-jalcalaroot` (also `10.0.0.0/16`) — `ServiceCidrOverlapExistingSubnetsCidr` at apply time. Set to `172.16.0.0/16` (purely virtual, never routed on the VNet, so any non-overlapping range works).
- **`default_node_pool_vm_size` and `default_node_pool_node_count` are both subscription-quota-constrained, found empirically, not by reading docs first:** `Standard_D2s_v5` isn't in this subscription's allowed SKU list for `eastus` (400 `BadRequest`, full allowed list is v7-generation D/E/F plus a few specialized series) — swapped for `Standard_D2s_v7`. Separately, **total regional vCPU quota is only 4** — not per-SKU, the whole region — so with one 2-vCPU node already running, `node_count` tops out at **2**, not 3+, without requesting an Azure quota increase first (`ErrCode_InsufficientVCPUQuota`).
- **Neither the ACI Connector's nor AGIC's auto-created managed identity gets any RBAC automatically — for either addon.** This contradicts what the docs imply about "bring your own" setups being handled for you. Both failed at runtime until these were added explicitly in `aks.tf`:
  - ACI Connector (`aci_connector_linux.connector_identity`) needs **Network Contributor** on `network_aks_virtual_nodes_subnet_id` — without it, the connector pod crash-loops with `AuthorizationFailed` on `subnets/read` the instant it tries to join a container to the subnet.
  - AGIC (`ingress_application_gateway.ingress_application_gateway_identity`) needs **three** separate grants: `Contributor` on the Application Gateway itself, `Reader` on its resource group, *and* **Network Contributor on `network_appgw_subnet_id`** (join/action) — missing any one produces a different opaque error (`ApplicationGatewayForbidden` for the first two, `ApplicationGatewayInsufficientPermissionOnSubnet` for the third). All three are needed because the subnet and (in a real deployment) the gateway can live in a different resource group than the cluster.
  - RBAC propagation after these role assignments can lag a few minutes — a `kubectl delete pod` restart of the connector/AGIC pod that still shows the old `AuthorizationFailed` error doesn't mean the role assignment is wrong, it may just not have propagated yet. Give it 2-3 minutes and retry before assuming the permission itself is incorrect.
- **Virtual Nodes pods need an explicit image pull secret — the kubelet identity's `AcrPull` role (`acr.tf`) only covers the real node pool.** The ACI Connector creates container groups with no managed identity for registry auth, so pulling from ACR fails with `InaccessibleImage` unless the pod has `imagePullSecrets` pointing at a `docker-registry` secret. Generate scoped, non-expiring credentials with an ACR token (`az acr token create ... --scope-map _repositories_pull`) rather than enabling the ACR admin account — see README step 4.
- **ACI (Virtual Nodes) has no overcommit — `resources.requests` must equal `resources.limits`, exactly, for both cpu and memory.** A pod with `requests: 100m` / `limits: 250m` gets rejected at the Azure API level with `ContainerLimitGreaterThanContainerGroupTotalRequest` the moment the ACI Connector tries to create the container group. `k8s/deployment.yaml` sets both to the same value on purpose.
- **Use `spec.ingressClassName`, never the `kubernetes.io/ingress.class` annotation, to select AGIC.** Setting the annotation to the *IngressClass resource's name* (`azure-application-gateway`) looks right and produces no error or warning from AGIC — it silently never processes the Ingress at all, and AGIC just keeps re-applying its empty default/catch-all config (a `placeholder`/`default*`-named pool, listener, and rule with no hostname and no backend). The only symptom is the site not responding; nothing in AGIC's logs calls out the annotation as wrong. `k8s/ingress.yaml` uses `spec.ingressClassName: azure-application-gateway` instead.

## Backend

Same Azure Blob Storage backend as `azure-container-apps-poc` and `jalcalaroot-azure-bootstrap` (`sttfstatejalcalaroot` in resource group `jalcalaroot`, `use_azuread_auth = true`), different key: `aks-containers-poc/terraform.tfstate`.

## `subscription_id`

Same gotcha as every other project here: set via `TF_VAR_subscription_id`, not `ARM_SUBSCRIPTION_ID`.

## Let's Encrypt rate limits

`acme_server_url` defaults to production (5 duplicate certs/domain/week). Switch to the [staging directory](https://letsencrypt.org/docs/staging-environment/) while iterating.

## Certificate renewal

Same limitation as `azure-container-apps-poc`: `acme_certificate` only re-issues within 30 days of expiry, and only when `terraform apply` actually runs — nothing here triggers that on a schedule. After a renewal, the Kubernetes Secret needs to be re-created (`kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`) for AGIC to pick up the new cert.

## CI/CD

Two dedicated OIDC identities (`ci_identities.tf`), same pattern as `azure-container-apps-poc`: `aks-containers-poc-agent` (apply) and `aks-containers-poc-plan` (read-only). RBAC scoped resource-by-resource, not blanket Contributor over a shared resource group.

- **`Contributor` doesn't include `Microsoft.Authorization/roleAssignments/write`.** The agent needs to create `azurerm_role_assignment.aks_acr_pull` (grants `AcrPull` to the cluster's kubelet identity, in `acr.tf`) - Contributor alone 403s on that. Fixed by granting the agent `Role Based Access Control Administrator` scoped to just the ACR resource (not the whole resource group) - lets it manage role assignments *on that one resource* without broader access. Didn't hit this in `azure-container-apps-poc` because nothing there needed the agent itself to grant a role at apply time.
- **Same Log Analytics Contributor gap as `azure-container-apps-poc`.** `oms_agent` needs the workspace's shared key (`Microsoft.OperationalInsights/workspaces/sharedKeys/action`), excluded from `Reader` on purpose - needs `Log Analytics Contributor`.
- **Same Storage Account Reader gap as `azure-container-apps-poc`.** `Storage Blob Data Contributor` is data-plane only; the `data.azurerm_storage_account.tfstate` block needs a management-plane `Reader` too.
- **The weekly schedule on `terraform-apply.yml` only renews the Let's Encrypt certificate - it does NOT update the cluster.** Unlike the Container Apps POC (where the cert is read live), here the cert is baked into a Kubernetes Secret a human created once. A renewed cert sitting in Terraform state does nothing until someone re-runs the `kubectl create secret tls` step against the live cluster.

## Consumers

None — this is a leaf project, nothing else reads its outputs.

## Relationship to the network project

Reads (copied values, no `terraform_remote_state`): `network_vnet_id`, `network_aks_subnet_id`, `network_aks_virtual_nodes_subnet_id`, `network_appgw_subnet_id`, `network_log_analytics_workspace_id`. The virtual-nodes subnet doesn't exist in the versioned network module — it was added directly to the consuming environment's root module (same approach as the Container Apps subnet), to avoid bumping that module's version for a POC-specific addition.
