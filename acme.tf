# Certificado Let's Encrypt via DNS-01, mismo mecanismo que
# azure-container-apps. A diferencia de ese proyecto, ACA NO pasa por
# Key Vault: AGIC no lee el certificado de un Key Vault como hacia
# Application Gateway standalone - lo toma de un Kubernetes TLS Secret
# referenciado en el Ingress (ver k8s/ingress.yaml). Menos piezas moviendose
# para lo que este proyecto necesita.
#
# Usamos common_name (no certificate_request_pem/tls_cert_request) a
# proposito: certificate_pem/private_key_pem solo vienen poblados cuando
# acme_certificate genera su propia key - con un CSR externo quedan vacios
# (gotcha real que ya pisamos en azure-container-apps).
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

resource "acme_certificate" "this" {
  account_key_pem = acme_registration.this.account_key_pem
  common_name     = local.fqdn
  key_type        = "RSA2048"

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_ZONE_NAME       = data.azurerm_dns_zone.this.name
      AZURE_RESOURCE_GROUP  = data.azurerm_dns_zone.this.resource_group_name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }
}

# Segundo certificado, para la UI de Argo CD - misma acme_registration
# (mismo account key), recurso separado (no un for_each sobre una lista de
# hosts) para no arriesgar el cert de hello-world que ya esta en uso.
resource "acme_certificate" "argocd" {
  account_key_pem = acme_registration.this.account_key_pem
  common_name     = local.argocd_fqdn
  key_type        = "RSA2048"

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_ZONE_NAME       = data.azurerm_dns_zone.this.name
      AZURE_RESOURCE_GROUP  = data.azurerm_dns_zone.this.resource_group_name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }
}

# Las 3 apps demo de k8s-apps - for_each en vez de un recurso explicito por
# app (a diferencia de hello-world/argocd arriba): son 3 certs idénticos
# salvo el hostname, sin ningun otro cert en uso que arriesgar al tocar
# este bloque despues.
resource "acme_certificate" "demo_apps" {
  for_each = local.demo_apps_fqdns

  account_key_pem = acme_registration.this.account_key_pem
  common_name     = each.value
  key_type        = "RSA2048"

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_ZONE_NAME       = data.azurerm_dns_zone.this.name
      AZURE_RESOURCE_GROUP  = data.azurerm_dns_zone.this.resource_group_name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }
}
