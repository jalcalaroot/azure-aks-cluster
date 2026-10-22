# Diagnostic settings of the networking resources, sent to the Log Analytics
# workspace shared through var.network_log_analytics_workspace_id.

resource "azurerm_monitor_diagnostic_setting" "app_gateway" {
  name                       = "diag-app-gateway"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "app_gateway_public_ip" {
  name                       = "diag-pip-app-gateway"
  target_resource_id         = azurerm_public_ip.appgw.id
  log_analytics_workspace_id = var.network_log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
