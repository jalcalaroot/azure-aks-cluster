output "fqdn" {
  description = "Dominio publico final"
  value       = local.fqdn
}

output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "node_resource_group" {
  description = "Resource group administrado por AKS (MC_*) - ahi vive el Application Gateway real, el Public IP, etc."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "certificate_pem" {
  description = "Certificado Let's Encrypt en PEM - usar junto a private_key_pem para crear el TLS Secret de Kubernetes (ver README)"
  value       = "${acme_certificate.this.certificate_pem}${acme_certificate.this.issuer_pem}"
  sensitive   = true
}

output "certificate_private_key_pem" {
  description = "Clave privada del certificado en PEM - sensible, usar solo para crear el TLS Secret de Kubernetes"
  value       = acme_certificate.this.private_key_pem
  sensitive   = true
}

output "argocd_fqdn" {
  description = "Dominio publico de la UI de Argo CD"
  value       = local.argocd_fqdn
}

output "argocd_certificate_pem" {
  description = "Certificado Let's Encrypt de Argo CD en PEM - usar junto a argocd_certificate_private_key_pem para crear el TLS Secret argocd-server-tls (ver README)"
  value       = "${acme_certificate.argocd.certificate_pem}${acme_certificate.argocd.issuer_pem}"
  sensitive   = true
}

output "argocd_certificate_private_key_pem" {
  description = "Clave privada del certificado de Argo CD en PEM - sensible, usar solo para crear el TLS Secret argocd-server-tls"
  value       = acme_certificate.argocd.private_key_pem
  sensitive   = true
}

output "demo_apps_fqdns" {
  description = "Dominios publicos de las 3 apps demo de k8s-apps"
  value       = local.demo_apps_fqdns
}

output "demo_apps_certificate_pem" {
  description = "Certificado Let's Encrypt en PEM por app, para crear el TLS Secret de Kubernetes de cada Ingress en k8s-apps"
  value       = { for app, cert in acme_certificate.demo_apps : app => "${cert.certificate_pem}${cert.issuer_pem}" }
  sensitive   = true
}

output "demo_apps_certificate_private_key_pem" {
  description = "Clave privada por app - sensible, usar solo para crear el TLS Secret de Kubernetes de cada Ingress en k8s-apps"
  value       = { for app, cert in acme_certificate.demo_apps : app => cert.private_key_pem }
  sensitive   = true
}
