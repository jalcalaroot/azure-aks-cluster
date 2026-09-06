# Misma zone existente que azure-container-apps (azure.jalcalaroot.com,
# ya delegada) - agregamos el registro "aks" en vez de "container".
data "azurerm_dns_zone" "this" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_dns_a_record" "aks" {
  name                = var.dns_record_name
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = data.azurerm_dns_zone.this.resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw.ip_address]
}
