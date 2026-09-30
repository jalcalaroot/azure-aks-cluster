# Azure AKS Cluster

A hello-world container served over HTTPS on a custom domain, running on **Azure Kubernetes Service (AKS)**, scheduled on a **Virtual Node** (ACI-backed, no VM behind the pod), exposed via **AGIC** (Application Gateway Ingress Controller) with a **Let's Encrypt** certificate. Also hosts **Argo CD** (Helm, `argocd` namespace, real node pool — see CLAUDE.md), the GitOps controller for this cluster's demo apps.

## Architecture

```
Azure DNS (azure.jalcalaroot.com)
 ├─ aks.azure.jalcalaroot.com          ──┐
 ├─ argocd.azure.jalcalaroot.com       ──┤
 ├─ podinfo.azure.jalcalaroot.com      ──┤
 ├─ game-2048.azure.jalcalaroot.com    ──┤
 └─ uptime-kuma.azure.jalcalaroot.com  ──┤
                                          ▼
        Application Gateway (AGIC, native multi-site)
        one Let's Encrypt cert per host (K8s TLS Secret)
                                          │
        ───── VNet-internal only below this line ─────
                                          │
AKS cluster (managed control plane)
 ├─ snet-aks (real node) — system components + Argo CD + KEDA
 │    ├─ CoreDNS, kube-proxy, Azure CNS, AGIC (addon), ACI connector
 │    ├─ Argo CD (Helm, 7 pods) — GitOps target: k8s-apps (separate repo)
 │    └─ KEDA (Helm, 3 pods) — ScaledObjects live in k8s-apps
 └─ snet-aks-virtual-nodes (ACI-backed) — every app pod runs here
      ├─ hello-world (Deployment, image: ACR)
      └─ podinfo / game-2048 / uptime-kuma / headlamp (Argo CD-managed, k8s-apps;
         headlamp actually runs on the real node pool - see k8s-apps/README.md)
```

This project consumes an **existing** VNet, DNS zone, and Log Analytics Workspace provisioned by [`azure-virtual-network`](https://github.com/jalcalaroot/azure-virtual-network); it does not create its own virtual network.

## Resources deployed

| Resource | Purpose | Docs |
|---|---|---|
| Resource Group | Container for everything below, own lifecycle | [Manage resource groups](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal) |
| AKS cluster | Real node pool (system components, 2 nodes by default) plus the Virtual Nodes add-on for the actual workload | [AKS overview](https://learn.microsoft.com/en-us/azure/aks/what-is-aks) |
| Virtual Nodes (ACI connector) | Runs the hello-world pod as an ACI container group, no VM | [Virtual nodes](https://learn.microsoft.com/en-us/azure/aks/virtual-nodes) |
| Azure Container Registry (Basic) | Hosts the `hello-world` image; built on [`Azure/avm-res-containerregistry-registry` v0.8.0](https://registry.terraform.io/modules/Azure/avm-res-containerregistry-registry/azurerm/0.8.0) | [ACR overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-intro) |
| Application Gateway (Standard_v2) + AGIC | Public entry point; AGIC reconfigures it automatically from Kubernetes `Ingress` resources | [AGIC overview](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) |
| Public IP (Standard) | Attached to the Application Gateway | [Public IP addresses](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses) |
| Azure DNS Zone (existing, not created here) | Hosts the `A` record for the public hostname | [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) |
| Let's Encrypt certificates (x5, via ACME DNS-01) | One per public host, delivered to the cluster as its own Kubernetes TLS Secret | [Let's Encrypt](https://letsencrypt.org/how-it-works/) |
| Container Insights (`oms_agent`) | AKS-specific monitoring, forwarded to an existing Log Analytics Workspace | [Container insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview) |
| Argo CD (Helm, `argocd` namespace) | GitOps controller, manages 4 apps from [`k8s-apps`](https://github.com/jalcalaroot/k8s-apps) | [argo-cd chart](https://github.com/argoproj/argo-helm) |
| KEDA (Helm, `keda` namespace) | Event-driven pod autoscaling | [KEDA docs](https://keda.sh/docs/latest/) |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) + `kubectl`, logged in via `az login`
- [Docker](https://docs.docker.com/get-docker/)
- [Helm](https://helm.sh/docs/intro/install/) (to install Argo CD and KEDA)
- An existing VNet with: a subnet for AKS nodes, a subnet delegated to `Microsoft.ContainerInstance/containerGroups` for Virtual Nodes, and a subnet for Application Gateway
- An existing Log Analytics Workspace and Azure DNS Zone

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

1. `az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw cluster_name)`
2. Build and push the image: `ACR=$(terraform output -raw acr_login_server); az acr login --name "${ACR%%.*}"; docker build -t "$ACR/hello-world:latest" ./docker; docker push "$ACR/hello-world:latest"`
3. Create the TLS secret from the ACME cert Terraform already issued: `terraform output -raw certificate_pem`/`certificate_private_key_pem` → `kubectl create secret tls hello-world-tls`
4. Create an ACR pull secret for the Virtual Node (the ACI Connector doesn't pull via managed identity): `az acr token create` → `kubectl create secret docker-registry acr-pull-secret`
5. Substitute the `<ACR_LOGIN_SERVER>`/`<FQDN>` placeholders in `k8s/*.yaml` and `kubectl apply -f k8s/`
6. Wait for AGIC to reconfigure the Application Gateway, then visit `https://$FQDN`
7. Install Argo CD (Helm) — create its TLS secret the same way, then `helm install argocd argo/argo-cd -n argocd -f argocd/values.yaml`. Initial admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
8. Install KEDA (Helm): `helm install keda kedacore/keda -n keda --create-namespace -f keda/values.yaml`
9. Bootstrap [`k8s-apps`](https://github.com/jalcalaroot/k8s-apps) so Argo CD starts syncing it: `kubectl apply -f` the `applicationset-aks.yaml`/`headlamp-application.yaml` bootstrap manifests

Full command-by-command runbook, including the teardown order, in [CLAUDE.md](CLAUDE.md).

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `subscription_id` | — | via `TF_VAR_subscription_id` |
| `acme_email` | — | via `TF_VAR_acme_email` |
| `owner` | — | for resource tags |
| `location` | `eastus` | must match your VNet's region |
| `network_aks_subnet_id` / `network_aks_virtual_nodes_subnet_id` / `network_appgw_subnet_id` / `network_log_analytics_workspace_id` | — | from your network project |
| `acr_name` | `acrakscluster` | globally unique |
| `sku_tier` | `Free` | AKS control plane SKU |
| `default_node_pool_vm_size` | `Standard_D2s_v7` | hosts system components only |
| `default_node_pool_node_count` | `2` | tune to your subscription's regional vCPU quota |
| `dns_zone_name` / `dns_zone_resource_group_name` | `azure.jalcalaroot.com` / `jalcalaroot` | must already exist |
| `dns_record_name` | `aks` | final FQDN = `<dns_record_name>.<dns_zone_name>` |
| `dns_record_name_argocd` | `argocd` | Argo CD UI FQDN |
| `dns_record_name_podinfo` / `dns_record_name_game_2048` / `dns_record_name_uptime_kuma` | `podinfo` / `game-2048` / `uptime-kuma` | FQDNs for the 3 `k8s-apps` demo apps |
| `acme_server_url` | Let's Encrypt production | use staging while iterating |

## Outputs

| Output | Description |
|---|---|
| `fqdn` | Public hostname |
| `app_gateway_public_ip` | Application Gateway's public IP |
| `acr_login_server` | For `docker build`/`push` |
| `cluster_name` / `resource_group_name` | For `az aks get-credentials` |
| `node_resource_group` | AKS-managed `MC_*` resource group |
| `certificate_pem` / `certificate_private_key_pem` | Sensitive — for the Kubernetes TLS Secret |
| `argocd_fqdn` | Argo CD UI public hostname |
| `argocd_certificate_pem` / `argocd_certificate_private_key_pem` | Sensitive — for the `argocd-server-tls` Secret |
| `demo_apps_fqdns` | Public hostnames for the 3 `k8s-apps` demo apps |
| `demo_apps_certificate_pem` / `demo_apps_certificate_private_key_pem` | Sensitive, keyed by app |

## CI/CD

GitHub Actions, authenticated to Azure via OIDC (Workload Identity Federation) — no secrets or static credentials stored in GitHub.

| Workflow | Trigger | Identity | What it does |
|---|---|---|---|
| `terraform-plan.yml` | Pull request | `aks-cluster-plan` (read-only) | `fmt -check`, `validate`, tflint, Checkov + [custom RBAC rules](https://github.com/jalcalaroot/johan-cloud-policies) (blocking), `plan`, [Checkov plan scan](https://github.com/jalcalaroot/gha-checkov-plan-scan) (non-blocking), posts the plan as a PR comment |
| `terraform-apply.yml` | Push to `main`; weekly schedule for cert renewal | `aks-cluster-agent` (scoped to this project's resources only) | `plan` + `apply` |
| `gitleaks.yml` | PR / push to `main` | — | Secret scanning |
| `docker-scan.yml` | PR / push to `main`, on `docker/**` changes | — | Builds the image (no push), [Trivy](https://github.com/aquasecurity/trivy) scan — reports all findings to the Security tab, blocks on fixable `CRITICAL`/`HIGH` |

`aks-cluster-agent`/`aks-cluster-plan` live in their own persistent Terraform root ([`./ci`](./ci)), separate from this project's destroyable state — identities survive teardown/redeploy. Required GitHub repository variables: `ARM_CLIENT_ID_AGENT`, `ARM_CLIENT_ID_PLAN`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `OWNER`, `NETWORK_AKS_SUBNET_ID`, `NETWORK_AKS_VIRTUAL_NODES_SUBNET_ID`, `NETWORK_APPGW_SUBNET_ID`, `NETWORK_LOG_ANALYTICS_WORKSPACE_ID`, plus the `ACME_EMAIL` secret.

See [CLAUDE.md](CLAUDE.md) for design decisions, RBAC breakdown, and full project history.
