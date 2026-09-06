# Certificado Let's Encrypt via DNS-01, mismo mecanismo que
# azure-container-apps-poc. A diferencia de ese proyecto, ACA NO pasa por
# Key Vault: AGIC no lee el certificado de un Key Vault como hacia
# Application Gateway standalone - lo toma de un Kubernetes TLS Secret
# referenciado en el Ingress (ver k8s/ingress.yaml). Menos piezas moviendose
# para lo que esta POC necesita.
#
# Usamos common_name (no certificate_request_pem/tls_cert_request) a
# proposito: certificate_pem/private_key_pem solo vienen poblados cuando
# acme_certificate genera su propia key - con un CSR externo quedan vacios
# (gotcha real que ya pisamos en azure-container-apps-poc).
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
