# Application Gateway "bring your own" para AGIC (Application Gateway
# Ingress Controller) - lo creamos nosotros (para tener el Public IP como
# recurso propio y poder wirear el DNS limpio) y se lo pasamos al cluster
# via `ingress_application_gateway.gateway_id` en aks.tf. A partir de ahi,
# AGIC reconfigura los listeners/backend pools/reglas segun los recursos
# Ingress de Kubernetes - por eso el backend_address_pool/http_listener/
# request_routing_rule de aca abajo son solo un placeholder minimo valido
# (Terraform los exige al crear el recurso) que AGIC va a sobreescribir en
# cuanto se aplique el primer Ingress. El lifecycle.ignore_changes evita que
# el proximo `terraform apply` pelee con lo que AGIC ya reconfiguro.
resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.app_gateway_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_application_gateway" "this" {
  #checkov:skip=CKV_AZURE_217:el placeholder HTTP es temporal - AGIC reemplaza los listeners al aplicar el primer Ingress
  #checkov:skip=CKV_AZURE_218:idem - configuracion real de TLS la define el Ingress de Kubernetes, no este placeholder
  #checkov:skip=CKV_AZURE_120:WAF_v2 no justificado por costo en este proyecto
  name                = var.app_gateway_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = var.app_gateway_sku_capacity
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = var.network_appgw_subnet_id
  }

  frontend_ip_configuration {
    name                 = "frontend-public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  # Placeholder minimo - AGIC lo reemplaza al aplicar el Ingress real.
  backend_address_pool {
    name = "placeholder-pool"
  }

  backend_http_settings {
    name                  = "placeholder-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
  }

  http_listener {
    name                           = "placeholder-listener"
    frontend_ip_configuration_name = "frontend-public"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "placeholder-rule"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = "placeholder-listener"
    backend_address_pool_name  = "placeholder-pool"
    backend_http_settings_name = "placeholder-settings"
  }

  lifecycle {
    ignore_changes = [
      frontend_port,
      backend_address_pool,
      backend_http_settings,
      http_listener,
      request_routing_rule,
      probe,
      ssl_certificate,
      url_path_map,
      redirect_configuration,
      tags,
    ]
  }
}
