# Identidades de CI para GitHub Actions via OIDC - mismos "agent"/"plan" que
# antes, pero AHORA en un state propio, separado del cluster/ACR/App Gateway
# (ver CLAUDE.md, seccion "Identidades de CI en state propio", para el
# porque). Viven en el resource group
# compartido "jalcalaroot" (nunca se destruye), no en el resource group
# propio del cluster (rg-aks-cluster, que si se destruye cuando el proyecto
# esta idle).
data "azurerm_resource_group" "shared" {
  name = "jalcalaroot"
}

resource "azurerm_user_assigned_identity" "ci_agent" {
  name                = "aks-cluster-agent"
  resource_group_name = data.azurerm_resource_group.shared.name
  location            = data.azurerm_resource_group.shared.location
}

resource "azurerm_user_assigned_identity" "ci_plan" {
  name                = "aks-cluster-plan"
  resource_group_name = data.azurerm_resource_group.shared.name
  location            = data.azurerm_resource_group.shared.location
}

# Subject claims segun el formato ACTUAL de GitHub para este repo
# (confirmado via `gh api repos/jalcalaroot/azure-aks-cluster/actions/oidc/customization/sub`).
# Push a main y schedule (cron) presentan el MISMO subject claim
# (ref:refs/heads/main) - por eso una sola federated credential en "agent"
# alcanza para ambos triggers de terraform-apply.yml.
resource "azurerm_federated_identity_credential" "ci_agent_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_agent.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:jalcalaroot@22682982/azure-aks-cluster@1359405750:ref:refs/heads/main"
}

resource "azurerm_federated_identity_credential" "ci_plan_pr" {
  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_plan.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:jalcalaroot@22682982/azure-aks-cluster@1359405750:pull_request"
}
