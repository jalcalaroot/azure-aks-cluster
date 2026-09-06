locals {
  base_tags = {
    ambiente    = var.environment
    propietario = var.owner
    proyecto    = var.project
  }

  tags = merge(local.base_tags, var.tags)

  fqdn = "${var.dns_record_name}.${var.dns_zone_name}"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}
