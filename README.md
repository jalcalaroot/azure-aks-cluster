# Azure AKS Containers POC

A hello-world container served over HTTPS on a custom domain, running on **Azure Kubernetes Service (AKS)**, scheduled on a **Virtual Node** (ACI-backed — the AKS equivalent of an EKS Fargate profile, no VM behind the pod), exposed via **AGIC** (Application Gateway Ingress Controller) with a **Let's Encrypt** certificate.

## Architecture

```
                              Internet
                                 |
                    Application Gateway (public, managed by AGIC)
                    TLS termination (K8s TLS Secret) + HTTP -> HTTPS redirect
                                 |
                    ───── VNet-internal only below this line ─────
                                 |
                          AKS cluster
              ┌──────────────────┴──────────────────┐
       snet-aks (real node)              snet-aks-virtual-nodes (ACI-backed)
       system components only            hello-world pod (nginx:alpine)
```

Application Gateway is the only public entry point. The hello-world pod runs on a Virtual Node — no VM behind it, billed per second, scheduled there via `nodeSelector`/`tolerations` (see `k8s/deployment.yaml`), same mechanism an EKS Fargate profile uses to claim pods by selector.

This project consumes an **existing** VNet, DNS zone, and Log Analytics Workspace — it does not create any of them.

## Resources deployed

| Resource | Purpose | Docs |
|---|---|---|
| Resource Group | Container for everything below | [Manage resource groups](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal) |
| AKS cluster | 1 real node (system components) + Virtual Nodes add-on for the actual workload | [AKS overview](https://learn.microsoft.com/en-us/azure/aks/what-is-aks) |
| Virtual Nodes (ACI connector) | Runs the hello-world pod as an ACI container group, no VM | [Virtual nodes](https://learn.microsoft.com/en-us/azure/aks/virtual-nodes) |
| Azure Container Registry (Basic) | Hosts the `hello-world` image; admin disabled, cluster pulls via its kubelet identity | [ACR overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-intro) |
| Application Gateway (Standard_v2) + AGIC | Public entry point; AGIC reconfigures it automatically from Kubernetes `Ingress` resources | [AGIC overview](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) |
| Public IP (Standard) | Attached to the Application Gateway | [Public IP addresses](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses) |
| Azure DNS Zone (existing, not created here) | Hosts the `A` record for the public hostname | [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) |
| Let's Encrypt certificate (via ACME DNS-01) | Issued through the [`vancluever/acme`](https://registry.terraform.io/providers/vancluever/acme/latest/docs) Terraform provider, delivered to the cluster as a Kubernetes TLS Secret | [Let's Encrypt](https://letsencrypt.org/how-it-works/) |
| Container Insights (`oms_agent`) | AKS-specific monitoring, forwarded to an existing Log Analytics Workspace | [Container insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview) |

## Design notes

- **Virtual Nodes, not a standard node pool, for the workload.** This is the direct AKS analog of an EKS Fargate profile — the pod is claimed by a `nodeSelector`/`toleration` (`k8s/deployment.yaml`), same idea as a Fargate profile claiming pods by namespace/label selector.
- **Azure CNI flat networking, not Overlay.** Virtual Nodes isn't compatible with Azure CNI Overlay (confirmed against Microsoft's own docs: overlay is for when you *don't* need advanced features like virtual nodes). This means every pod — on the real node and on Virtual Nodes — gets a real, routable VNet IP, which is why `snet-aks-virtual-nodes` is a full `/24` rather than something smaller.
- **No Key Vault in this design**, unlike the Container Apps POC. AGIC doesn't read certificates from Key Vault the way a standalone Application Gateway does — it picks them up from a Kubernetes `Secret` referenced in the `Ingress` resource's `tls:` section. One less moving part.
- **The Application Gateway is "bring your own."** We create a minimal placeholder (required by Terraform to create the resource at all) and hand its ID to AGIC via `ingress_application_gateway.gateway_id`. AGIC then reconfigures the real listeners/backend pools/rules based on Kubernetes `Ingress` objects — `lifecycle.ignore_changes` on the Terraform resource stops `terraform apply` from fighting AGIC over those blocks afterward.
- **Kubernetes manifests are plain YAML, not Terraform-managed.** Consistent with how the Container Apps POC treats the Docker image (build/push is a manual step, not a Terraform resource) — `kubectl apply` is a separate, documented step after `terraform apply` creates the cluster.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) + `kubectl`, logged in via `az login`
- [Docker](https://docs.docker.com/get-docker/)
- An existing VNet with: a subnet for AKS nodes, a subnet delegated to `Microsoft.ContainerInstance/containerGroups` for Virtual Nodes, and a subnet for Application Gateway
- An existing Log Analytics Workspace
- An existing, already-delegated Azure DNS Zone

## Usage

```bash
az login
export TF_VAR_subscription_id="<subscription-id>"
export TF_VAR_acme_email="you@example.com"
export TF_VAR_owner="<your-name>"

terraform init
terraform apply \
  -var "network_aks_subnet_id=<...>" \
  -var "network_aks_virtual_nodes_subnet_id=<...>" \
  -var "network_appgw_subnet_id=<...>" \
  -var "network_log_analytics_workspace_id=<...>"
```

1. **Get cluster credentials:**
   ```bash
   az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw cluster_name)
   ```
2. **Build and push the image:**
   ```bash
   ACR=$(terraform output -raw acr_login_server)
   az acr login --name "${ACR%%.*}"
   docker build -t "$ACR/hello-world:latest" ./docker
   docker push "$ACR/hello-world:latest"
   ```
3. **Create the TLS secret** from the ACME certificate Terraform already issued:
   ```bash
   terraform output -raw certificate_pem > /tmp/tls.crt
   terraform output -raw certificate_private_key_pem > /tmp/tls.key
   kubectl create secret tls hello-world-tls --cert=/tmp/tls.crt --key=/tmp/tls.key
   rm /tmp/tls.crt /tmp/tls.key
   ```
4. **Apply the manifests** (substitute the placeholders first):
   ```bash
   FQDN=$(terraform output -raw fqdn)
   sed -i "s|<ACR_LOGIN_SERVER>|$ACR|" k8s/deployment.yaml
   sed -i "s|<FQDN>|$FQDN|g" k8s/ingress.yaml
   kubectl apply -f k8s/
   ```
5. Wait a few minutes for AGIC to reconfigure the Application Gateway, then visit `https://$FQDN`.

```bash
kubectl delete -f k8s/
terraform destroy
```

Renewing the certificate and Let's Encrypt rate limits: see [CLAUDE.md](CLAUDE.md).

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `subscription_id` | — | via `TF_VAR_subscription_id` |
| `acme_email` | — | via `TF_VAR_acme_email` |
| `owner` | — | for resource tags |
| `location` | `eastus` | must match your VNet's region |
| `network_aks_subnet_id` / `network_aks_virtual_nodes_subnet_id` / `network_appgw_subnet_id` / `network_log_analytics_workspace_id` | — | from your network project |
| `acr_name` | `acrakscontainerspoc` | globally unique |
| `sku_tier` | `Free` | AKS control plane SKU |
| `default_node_pool_vm_size` | `Standard_D2s_v5` | the one real node, hosts system components only |
| `dns_zone_name` / `dns_zone_resource_group_name` | `azure.jalcalaroot.com` / `jalcalaroot` | must already exist |
| `dns_record_name` | `aks` | final FQDN = `<dns_record_name>.<dns_zone_name>` |
| `acme_server_url` | Let's Encrypt production | use staging while iterating |

## Outputs

| Output | Description |
|---|---|
| `fqdn` | Public hostname |
| `app_gateway_public_ip` | Application Gateway's public IP |
| `acr_login_server` | For `docker build`/`push` |
| `cluster_name` / `resource_group_name` | For `az aks get-credentials` |
| `node_resource_group` | AKS-managed `MC_*` resource group |
| `certificate_pem` / `certificate_private_key_pem` | Sensitive — for creating the Kubernetes TLS Secret |

## CI/CD

GitHub Actions, authenticated to Azure via OIDC (Workload Identity Federation) — no secrets or static credentials stored in GitHub, same pattern as `azure-container-apps-poc`.

| Workflow | Trigger | Identity | What it does |
|---|---|---|---|
| `terraform-plan.yml` | Pull request | `aks-containers-poc-plan` (read-only) | `fmt -check`, `validate`, tflint, Checkov (blocking), `plan`, posts the plan as a PR comment |
| `terraform-apply.yml` | Push to `main`, and weekly on a schedule | `aks-containers-poc-agent` (scoped to this project's resources only) | `plan` + `apply` |
| `gitleaks.yml` | PR / push to `main` | — | Secret scanning |

**The weekly schedule only renews the certificate in Let's Encrypt — it does not update the cluster.** Unlike the Container Apps POC, the cert isn't read live by anything; it's baked into a Kubernetes Secret that a human created once via `kubectl`. After a renewal, re-run the `kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -` step manually (see CLAUDE.md) for AGIC to actually pick up the new certificate.

Both identities are scoped resource-by-resource, same philosophy as `azure-container-apps-poc` — see CLAUDE.md for the full RBAC breakdown, including a permission gap (`Role Based Access Control Administrator` on the ACR) that doesn't show up in the Container Apps POC but is required here for the agent to grant `AcrPull` to the cluster's kubelet identity.

Required GitHub repository variables (Settings → Secrets and variables → Actions → Variables): `ARM_CLIENT_ID_AGENT`, `ARM_CLIENT_ID_PLAN`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `OWNER`, `NETWORK_AKS_SUBNET_ID`, `NETWORK_AKS_VIRTUAL_NODES_SUBNET_ID`, `NETWORK_APPGW_SUBNET_ID`, `NETWORK_LOG_ANALYTICS_WORKSPACE_ID`. Plus the `ACME_EMAIL` secret.

## Cost

Main ongoing costs: AKS control plane (free on the Free SKU), the one real VM node, Virtual Nodes (billed per second the pod actually runs, effectively free at hello-world scale), Application Gateway (hourly + capacity units) and its Public IP, ACR Basic (flat monthly), DNS queries, incremental Log Analytics ingestion. Estimate with the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

## Not covered

WAF on Application Gateway, Azure AD RBAC integration for the cluster, autoscaling, multi-region, network policies, automated cluster-side certificate rotation.
