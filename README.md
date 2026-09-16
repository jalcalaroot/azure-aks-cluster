# Azure AKS Cluster

A hello-world container served over HTTPS on a custom domain, running on **Azure Kubernetes Service (AKS)**, scheduled on a **Virtual Node** (ACI-backed — the AKS equivalent of an EKS Fargate profile, no VM behind the pod), exposed via **AGIC** (Application Gateway Ingress Controller) with a **Let's Encrypt** certificate. Also hosts **Argo CD** (Helm, `argocd` namespace, on the real node pool, not Virtual Nodes — see CLAUDE.md) — the GitOps controller, mirroring the same role it plays in [`aws-eks-cluster`](https://github.com/jalcalaroot/aws-eks-cluster).

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

Application Gateway is the only public entry point, serving all 5 hosts via AGIC's native multi-site support — one Ingress per host, no extra Application Gateway needed. hello-world and the 3 `k8s-apps` demo apps run on Virtual Nodes, no VM behind them, billed per second, scheduled there via `nodeSelector`/`tolerations` (see `k8s/deployment.yaml` and each app's `overlays/aks/patch-virtual-node.yaml` in `k8s-apps`), same mechanism an EKS Fargate profile uses to claim pods by selector. **Argo CD and KEDA run on the real node pool instead** — ACI/Virtual Nodes rejects any pod that declares `args` without an explicit `command` (relying on the image's own `ENTRYPOINT`, which is what almost the entire `argo-cd` chart does), found on the first real install; see CLAUDE.md. `metrics-server` also never returns pod metrics for anything on Virtual Nodes (confirmed repeatedly — see CLAUDE.md and `k8s-apps/CLAUDE.md`), so KEDA's `cpu`-trigger `ScaledObject`s don't actually scale the 3 Virtual Node apps, only `headlamp` (real node pool). The real node pool exists because AKS requires one, because Virtual Nodes can't run components needing `hostNetwork`/host access (CoreDNS, kube-proxy, AGIC, the ACI connector itself), and now also because Argo CD and KEDA need it — see CLAUDE.md for why this means AKS can't be as fully serverless as EKS.

This project consumes an **existing** VNet, DNS zone, and Log Analytics Workspace provisioned by a sibling network project; it does not create its own virtual network. Design rationale and implementation notes live in [CLAUDE.md](CLAUDE.md).

## Resources deployed

| Resource | Purpose | Docs |
|---|---|---|
| Resource Group | Container for everything below, own lifecycle | [Manage resource groups](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal) |
| AKS cluster | Real node pool (system components, 2 nodes by default) plus the Virtual Nodes add-on for the actual workload | [AKS overview](https://learn.microsoft.com/en-us/azure/aks/what-is-aks) |
| Virtual Nodes (ACI connector) | Runs the hello-world pod as an ACI container group, no VM | [Virtual nodes](https://learn.microsoft.com/en-us/azure/aks/virtual-nodes) |
| Azure Container Registry (Basic) | Hosts the `hello-world` image; admin user disabled | [ACR overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-intro) |
| Application Gateway (Standard_v2) + AGIC | Public entry point; AGIC reconfigures it automatically from Kubernetes `Ingress` resources | [AGIC overview](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) |
| Public IP (Standard) | Attached to the Application Gateway | [Public IP addresses](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses) |
| Azure DNS Zone (existing, not created here) | Hosts the `A` record for the public hostname | [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) |
| Let's Encrypt certificates (x5, via ACME DNS-01) | One per public host (`aks.*`, `argocd.*`, plus the 3 `k8s-apps` demo apps), each delivered to the cluster as its own Kubernetes TLS Secret | [Let's Encrypt](https://letsencrypt.org/how-it-works/) |
| User Assigned Managed Identities (x2) | CI/CD identities for GitHub Actions, federated via OIDC — no stored secrets | [Managed identities overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview) |
| Container Insights (`oms_agent`) | AKS-specific monitoring, forwarded to an existing Log Analytics Workspace | [Container insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview) |
| Argo CD (Helm, `argocd` namespace) | GitOps controller — 7 components on the real node pool (ACI can't run this chart's pods, see CLAUDE.md); UI at `argocd.azure.jalcalaroot.com`. Manages 4 apps from [`k8s-apps`](https://github.com/jalcalaroot/k8s-apps) (`applicationset-aks.yaml` + `headlamp-application.yaml`) | [argo-cd chart](https://github.com/argoproj/argo-helm) |
| KEDA (Helm, `keda` namespace) | Event-driven pod autoscaling — all 3 components on the **real node pool**, same reason as Argo CD (not Virtual Nodes, despite an earlier version of this doc saying otherwise). `cpu`-trigger `ScaledObject`s exist in `k8s-apps` but don't actually scale anything on Virtual Nodes — see CLAUDE.md | [KEDA docs](https://keda.sh/docs/latest/) |

## Design notes

- **Virtual Nodes, not a standard node pool, for the workload.** This is the direct AKS analog of an EKS Fargate profile — the pod is claimed by a `nodeSelector`/`toleration` (`k8s/deployment.yaml`), same idea as a Fargate profile claiming pods by namespace/label selector.
- **Azure CNI flat networking, not Overlay.** Virtual Nodes isn't compatible with Azure CNI Overlay (confirmed against Microsoft's own docs: overlay is for when you *don't* need advanced features like virtual nodes). This means every pod — on the real node and on Virtual Nodes — gets a real, routable VNet IP, which is why `snet-aks-virtual-nodes` is a full `/24` rather than something smaller.
- **No Key Vault in this design.** AGIC doesn't read certificates from Key Vault the way a standalone Application Gateway does — it picks them up from a Kubernetes `Secret` referenced in the `Ingress` resource's `tls:` section. One less moving part.
- **The Application Gateway is "bring your own."** Terraform creates a minimal placeholder (required to create the resource at all) and hands its ID to AGIC via `ingress_application_gateway.gateway_id`. AGIC then reconfigures the real listeners/backend pools/rules based on Kubernetes `Ingress` objects — `lifecycle.ignore_changes` on the Terraform resource stops `terraform apply` from fighting AGIC over those blocks afterward.
- **Kubernetes manifests are plain YAML, not Terraform-managed.** Terraform's job is the infrastructure, not the application — `kubectl apply` is a separate, documented step after `terraform apply` creates the cluster.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) + `kubectl`, logged in via `az login`
- [Docker](https://docs.docker.com/get-docker/)
- [Helm](https://helm.sh/docs/intro/install/) (to install Argo CD and KEDA)
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
4. **Create an ACR pull secret for the Virtual Node.** Unlike the real node pool (which pulls via the kubelet identity's `AcrPull` role), the ACI Connector creates its container groups without any managed identity for registry auth — pulling the image fails with `InaccessibleImage` without this:
   ```bash
   TOKEN_PASSWORD=$(az acr token create --name aci-pull-token --registry "${ACR%%.*}" \
     --scope-map _repositories_pull --query "credentials.passwords[0].value" -o tsv)
   kubectl create secret docker-registry acr-pull-secret \
     --docker-server="$ACR" --docker-username=aci-pull-token --docker-password="$TOKEN_PASSWORD"
   ```
5. **Apply the manifests** (substitute the placeholders first):
   ```bash
   FQDN=$(terraform output -raw fqdn)
   sed -i "s|<ACR_LOGIN_SERVER>|$ACR|" k8s/deployment.yaml
   sed -i "s|<FQDN>|$FQDN|g" k8s/ingress.yaml
   kubectl apply -f k8s/
   ```
6. Wait a few minutes for AGIC to reconfigure the Application Gateway, then visit `https://$FQDN`.
7. **Install Argo CD** (GitOps controller — not managed by Terraform, same reasoning as the hello-world manifests). Create its TLS secret from the second ACME cert Terraform already issued, substitute the hostname placeholder, then install:
   ```bash
   kubectl create namespace argocd
   terraform output -raw argocd_certificate_pem > /tmp/argocd-tls.crt
   terraform output -raw argocd_certificate_private_key_pem > /tmp/argocd-tls.key
   kubectl create secret tls argocd-server-tls -n argocd \
     --cert=/tmp/argocd-tls.crt --key=/tmp/argocd-tls.key
   rm /tmp/argocd-tls.crt /tmp/argocd-tls.key

   ARGOCD_FQDN=$(terraform output -raw argocd_fqdn)
   sed "s|<ARGOCD_FQDN>|$ARGOCD_FQDN|" argocd/values.yaml > /tmp/argocd-values.yaml

   helm repo add argo https://argoproj.github.io/argo-helm
   helm install argocd argo/argo-cd --version 10.8.2 -n argocd -f /tmp/argocd-values.yaml
   rm /tmp/argocd-values.yaml
   ```
   Wait for AGIC to pick up the new Ingress, then visit `https://$ARGOCD_FQDN`. Initial admin password:
   `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d` —
   delete that secret after first login, per Argo's own getting-started guide.
8. **Install KEDA** (event-driven pod autoscaling — not managed by Terraform, same reasoning as Argo CD). No placeholder to substitute — KEDA exposes nothing publicly, so there's no DNS/certificate/Ingress involved:
   ```bash
   helm repo add kedacore https://kedacore.github.io/charts
   helm install keda kedacore/keda --version 2.20.2 -n keda --create-namespace -f keda/values.yaml
   ```
   `ScaledObject`s live in [`k8s-apps`](https://github.com/jalcalaroot/k8s-apps) (podinfo/game-2048/headlamp) — see CLAUDE.md for why the `cpu` trigger doesn't actually scale anything for pods on Virtual Nodes.
9. **Bootstrap `k8s-apps`** (tells the Argo CD just installed to start watching/syncing it — `metrics-server` ships by default on AKS, no separate install needed unlike EKS):
   ```bash
   curl -sL https://raw.githubusercontent.com/jalcalaroot/k8s-apps/main/bootstrap/applicationset-aks.yaml | kubectl apply -f -
   curl -sL https://raw.githubusercontent.com/jalcalaroot/k8s-apps/main/bootstrap/headlamp-application.yaml | kubectl apply -f -
   ```

```bash
kubectl delete -f https://raw.githubusercontent.com/jalcalaroot/k8s-apps/main/bootstrap/applicationset-aks.yaml
kubectl delete -f https://raw.githubusercontent.com/jalcalaroot/k8s-apps/main/bootstrap/headlamp-application.yaml
helm uninstall keda -n keda
kubectl delete ns keda
helm uninstall argocd -n argocd
kubectl delete ns argocd
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
| `acr_name` | `acrakscluster` | globally unique |
| `sku_tier` | `Free` | AKS control plane SKU |
| `default_node_pool_vm_size` | `Standard_D2s_v7` | hosts system components only; the workload runs on the Virtual Node |
| `default_node_pool_node_count` | `2` | tune to your subscription's regional vCPU quota |
| `dns_zone_name` / `dns_zone_resource_group_name` | `azure.jalcalaroot.com` / `jalcalaroot` | must already exist |
| `dns_record_name` | `aks` | final FQDN = `<dns_record_name>.<dns_zone_name>` |
| `dns_record_name_argocd` | `argocd` | Argo CD UI FQDN = `<dns_record_name_argocd>.<dns_zone_name>` |
| `dns_record_name_podinfo` / `dns_record_name_game_2048` / `dns_record_name_uptime_kuma` | `podinfo` / `game-2048` / `uptime-kuma` | FQDNs for the 3 `k8s-apps` demo apps, same Application Gateway |
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
| `argocd_fqdn` | Argo CD UI public hostname |
| `argocd_certificate_pem` / `argocd_certificate_private_key_pem` | Sensitive — for creating the `argocd-server-tls` Secret |
| `demo_apps_fqdns` | Public hostnames for the 3 `k8s-apps` demo apps |
| `demo_apps_certificate_pem` / `demo_apps_certificate_private_key_pem` | Sensitive, keyed by app — for creating each app's `<app>-tls` Secret |

## Public URLs

| App | URL |
|---|---|
| hello-world | https://aks.azure.jalcalaroot.com |
| Argo CD | https://argocd.azure.jalcalaroot.com |
| podinfo | https://podinfo.azure.jalcalaroot.com |
| game-2048 | https://game-2048.azure.jalcalaroot.com |
| uptime-kuma | https://uptime-kuma.azure.jalcalaroot.com |

All 5 share the same Application Gateway via AGIC's multi-site support, one Let's Encrypt cert per host. The last 3 are deployed and managed by [`k8s-apps`](https://github.com/jalcalaroot/k8s-apps) via Argo CD, not by this repo — their `Ingress` manifests live there (`apps/<name>/overlays/aks/ingress.yaml`), referencing TLS Secrets (`<app>-tls`) created manually from this repo's `demo_apps_certificate_pem`/`demo_apps_certificate_private_key_pem` outputs, same flow as `hello-world-tls`/`argocd-server-tls` above.

## CI/CD

GitHub Actions, authenticated to Azure via OIDC (Workload Identity Federation) — no secrets or static credentials stored in GitHub.

| Workflow | Trigger | Identity | What it does |
|---|---|---|---|
| `terraform-plan.yml` | Pull request | `aks-cluster-plan` (read-only) | `fmt -check`, `validate`, tflint, Checkov + [custom RBAC rules](https://github.com/jalcalaroot/johan-cloud-policies) (blocking), `plan`, [Checkov plan scan](https://github.com/jalcalaroot/gha-checkov-plan-scan) (second pass against the resolved plan, not blocking — see CLAUDE.md), posts the plan as a PR comment |
| `terraform-apply.yml` | Push to `main`, and weekly on a schedule | `aks-cluster-agent` (scoped to this project's resources only) | `plan` + `apply` |
| `gitleaks.yml` | PR / push to `main` | — | Secret scanning |

**The weekly schedule only renews the certificate in Let's Encrypt — it does not update the cluster.** The cert isn't read live by anything; it's baked into a Kubernetes Secret that a human created once via `kubectl`. After a renewal, re-run the `kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -` step manually (see CLAUDE.md) for AGIC to actually pick up the new certificate.

Both identities are scoped resource-by-resource, never blanket `Contributor` over a shared resource group — see CLAUDE.md for the full RBAC breakdown, including a permission gap (`Role Based Access Control Administrator` on the ACR) required for the agent to grant `AcrPull` to the cluster's kubelet identity.

Required GitHub repository variables (Settings → Secrets and variables → Actions → Variables): `ARM_CLIENT_ID_AGENT`, `ARM_CLIENT_ID_PLAN`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `OWNER`, `NETWORK_AKS_SUBNET_ID`, `NETWORK_AKS_VIRTUAL_NODES_SUBNET_ID`, `NETWORK_APPGW_SUBNET_ID`, `NETWORK_LOG_ANALYTICS_WORKSPACE_ID`. Plus the `ACME_EMAIL` secret.

## Cost

Main ongoing costs: AKS control plane (free on the Free SKU), the real node(s), Virtual Nodes (billed per second the pod actually runs), Application Gateway (hourly + capacity units) and its Public IP, ACR Basic (flat monthly), DNS queries, incremental Log Analytics ingestion. hello-world alone is effectively free at this scale. Argo CD's 7 components (the 8th, `redisSecretInit`, is a one-shot Job) run 24/7 on the real node pool instead of Virtual Nodes (see CLAUDE.md) — at roughly 1.4 vCPU / 2.3 GB combined (see `argocd/values.yaml`'s resource requests) this is comfortably within the 2 already-provisioned `Standard_D2s_v7` nodes' spare capacity, so it's near-zero marginal cost rather than a separate Virtual-Nodes line item. `dex` and `notifications` (unused today) are kept enabled for parity with `aws-eks-cluster`. KEDA adds a further ~300m vCPU / ~384 MB combined (see `keda/values.yaml`) on Virtual Nodes — on the order of **US$10-12/month**, idle with no `ScaledObject` configured. Estimate with the [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

## Not covered

WAF on Application Gateway, Azure AD RBAC integration for the cluster, cluster/node autoscaling, pod autoscaling (KEDA installed but no `ScaledObject` configured), multi-region, network policies, automated cluster-side certificate rotation.
