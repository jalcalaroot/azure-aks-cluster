locals {
  # Keys en ingles para ser consistente con el resto de la cuenta
  # (aws-eks-cluster, el modulo tags de jalcalaroot-azure-bootstrap) -
  # este repo usaba claves en espanol, lo que hacia que
  # CKV2_CUSTOM_AZURE_3 (johan-cloud-policies) nunca pudiera verificar
  # Owner/Environment aqui, aunque el recurso si estuviera tageado.
  base_tags = {
    Environment = var.environment
    Owner       = var.owner
    Project     = var.project
  }

  tags = merge(local.base_tags, var.tags)

  fqdn        = "${var.dns_record_name}.${var.dns_zone_name}"
  argocd_fqdn = "${var.dns_record_name_argocd}.${var.dns_zone_name}"

  demo_apps_fqdns = {
    podinfo     = "${var.dns_record_name_podinfo}.${var.dns_zone_name}"
    game-2048   = "${var.dns_record_name_game_2048}.${var.dns_zone_name}"
    uptime-kuma = "${var.dns_record_name_uptime_kuma}.${var.dns_zone_name}"
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}
