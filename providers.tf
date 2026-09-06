terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 3.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

# El challenge DNS-01 (ver acme.tf) usa por defecto las mismas credenciales
# de `az login` que ya usa azurerm - ver azure-container-apps-poc/CLAUDE.md
# para el detalle, mismo mecanismo acá.
provider "acme" {
  server_url = var.acme_server_url
}
