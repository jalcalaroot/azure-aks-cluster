output "ci_agent_client_id" {
  value = azurerm_user_assigned_identity.ci_agent.client_id
}

output "ci_agent_principal_id" {
  value = azurerm_user_assigned_identity.ci_agent.principal_id
}

output "ci_plan_client_id" {
  value = azurerm_user_assigned_identity.ci_plan.client_id
}

output "ci_plan_principal_id" {
  value = azurerm_user_assigned_identity.ci_plan.principal_id
}
