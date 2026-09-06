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
