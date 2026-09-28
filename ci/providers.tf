# Root independiente del resto del repo (ver README) - sin ninguna
# dependencia de Azure Verified Modules, no hereda el rango acotado de
# azurerm que pide acr.tf en el root principal.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}
