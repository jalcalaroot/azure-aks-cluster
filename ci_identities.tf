# Identidades de CI para GitHub Actions vía OIDC (Workload Identity
# Federation) - sin ningun secreto de Azure almacenado en GitHub. Mismo
# patron que azure-container-apps: "agent" (apply, push+schedule a
# main) y "plan" (solo lectura, PRs), con RBAC acotado recurso por recurso
# en vez de Contributor sobre un resource group compartido.
data "azurerm_storage_account" "tfstate" {
  name                = "sttfstatejalcalaroot"
  resource_group_name = "jalcalaroot"
}

resource "azurerm_user_assigned_identity" "ci_agent" {
  name                = "aks-cluster-agent"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "ci_plan" {
  name                = "aks-cluster-plan"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Subject claims segun el formato ACTUAL de GitHub para este repo
# (confirmado via `gh api repos/jalcalaroot/azure-aks-cluster/actions/oidc/customization/sub`).
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

# --------------------------------------------------------------------------
# RBAC - acotado recurso por recurso.
# --------------------------------------------------------------------------

resource "azurerm_role_assignment" "ci_agent_rg_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_rg_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# "Contributor" NO incluye Microsoft.Authorization/roleAssignments/write -
# necesario para que el agent pueda crear azurerm_role_assignment.aks_acr_pull
# (AcrPull para la kubelet identity del cluster, en acr.tf). Acotado al ACR
# especifico, no a todo el resource group - el agent solo puede otorgar
# accesos SOBRE ese recurso puntual, no sobre cualquier cosa.
resource "azurerm_role_assignment" "ci_agent_acr_rbac_admin" {
  #checkov:skip=CKV2_CUSTOM_AZURE_1:RBAC Administrator es necesario aqui especificamente (ver comentario arriba: Contributor no incluye Microsoft.Authorization/roleAssignments/write), pero acotado al recurso ACR puntual, no a todo el resource group ni a la suscripcion - el agent solo puede otorgar accesos sobre ese recurso, no escalar mas alla de el.
  scope                = azurerm_container_registry.this.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

# DNS Zone existente - acotado a la zone especifica.
resource "azurerm_role_assignment" "ci_agent_dns_zone_contributor" {
  scope                = data.azurerm_dns_zone.this.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_dns_zone_reader" {
  scope                = data.azurerm_dns_zone.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# Subnets especificos en la VNet compartida - el agent necesita poder
# "unir" el cluster/App Gateway a estos subnets (join/action), no
# Contributor sobre la VNet entera.
resource "azurerm_role_assignment" "ci_agent_aks_subnet_network_contributor" {
  scope                = var.network_aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_agent_aks_virtual_nodes_subnet_network_contributor" {
  scope                = var.network_aks_virtual_nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_agent_appgw_subnet_network_contributor" {
  scope                = var.network_appgw_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

# Backend remoto: Storage Blob Data Contributor (data plane, lease de
# locking) + Reader (management plane, para que el data source
# azurerm_storage_account pueda leer el objeto ARM) - ambos gaps reales que
# ya pisamos ayer en azure-container-apps.
resource "azurerm_role_assignment" "ci_agent_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

resource "azurerm_role_assignment" "ci_agent_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# El cluster (oms_agent) necesita leer la shared key del Log Analytics
# Workspace para conectar Container Insights - "Reader" no alcanza (esa
# accion esta excluida a proposito), hace falta "Log Analytics
# Contributor". Mismo gap que pisamos ayer.
resource "azurerm_role_assignment" "ci_agent_log_analytics_contributor" {
  scope                = var.network_log_analytics_workspace_id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_log_analytics_reader" {
  scope                = var.network_log_analytics_workspace_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}
