terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Bajado de ~> 5.4 a >= 4.81.0, < 5.0.0 el 2026-09-28 al migrar acr.tf a
    # Azure/avm-res-containerregistry-registry/azurerm (pide exactamente ese
    # rango). azurerm_kubernetes_cluster/aci_connector_linux/
    # node_provisioning_profile (usados en aks.tf, que se queda crudo a
    # proposito - Virtual Nodes no tiene AVM viable, ver CLAUDE.md) se
    # confirmaron presentes en el schema real de v4.81 antes de bajar esto,
    # no se asumio que "funciona igual".
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.81.0, < 5.7.1"
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
# de `az login` que ya usa azurerm - ver azure-container-apps/CLAUDE.md
# para el detalle, mismo mecanismo acá.
provider "acme" {
  server_url = var.acme_server_url
}
