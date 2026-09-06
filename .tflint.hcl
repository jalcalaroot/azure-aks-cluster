plugin "azurerm" {
  enabled = true
  version = "0.32.0" # verificar/actualizar contra la última release de tflint-ruleset-azurerm
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Deshabilitada a proposito: sin prevent_destroy en ningun lado - el cluster,
# el Application Gateway placeholder y el ACR deben poder destruirse limpio
# con `terraform destroy`.
rule "azurerm_resources_missing_prevent_destroy" {
  enabled = false
}
