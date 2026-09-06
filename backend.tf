# Backend remoto real: mismo storage account de tfstate que
# jalcalaroot-azure-bootstrap y azure-container-apps-poc
# (sttfstatejalcalaroot, RG jalcalaroot), key distinto para no pisar esos
# states. use_azuread_auth = true - acceso 100% via RBAC, sin storage
# account keys (esa cuenta tiene shared_access_key_enabled = false).
terraform {
  backend "azurerm" {
    resource_group_name  = "jalcalaroot"
    storage_account_name = "sttfstatejalcalaroot"
    container_name       = "tfstate"
    key                  = "aks-containers-poc/terraform.tfstate"
    use_azuread_auth     = true
  }
}
