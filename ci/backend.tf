# Mismo storage account de tfstate que el resto de la cuenta
# (sttfstatejalcalaroot, RG jalcalaroot), key propio para no pisar el state
# principal de este repo (aks-cluster/terraform.tfstate). Root deliberadamente
# separado - ver CLAUDE.md, seccion "Identidades de CI en state propio".
terraform {
  backend "azurerm" {
    resource_group_name  = "jalcalaroot"
    storage_account_name = "sttfstatejalcalaroot"
    container_name       = "tfstate"
    key                  = "aks-cluster-ci/terraform.tfstate"
    use_azuread_auth     = true
  }
}
