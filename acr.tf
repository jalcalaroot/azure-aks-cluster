# Basic SKU alcanza para este proyecto. Admin user deshabilitado - el pull lo
# hace el cluster via su kubelet identity (ver acr_role_assignment.tf /
# aks.tf), no con credenciales admin embebidas.
resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_164:content trust requiere Premium SKU - no justificado para este proyecto
  #checkov:skip=CKV_AZURE_139:acceso publico intencional - Basic SKU no soporta Private Endpoint de todas formas
  #checkov:skip=CKV_AZURE_165:geo-replicacion requiere Premium SKU - una sola region en este proyecto
  #checkov:skip=CKV_AZURE_233:zone redundancy requiere Premium SKU
  #checkov:skip=CKV_AZURE_167:retention policy requiere Premium SKU - una sola imagen (hello-world:latest) en este proyecto
  #checkov:skip=CKV_AZURE_166:quarantine/scanning requiere Premium SKU
  #checkov:skip=CKV_AZURE_237:dedicated data endpoints requiere Premium SKU
  #checkov:skip=CKV_AZURE_163:vulnerability scanning requiere Premium SKU
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

# Equivalente Terraform de `az aks update --attach-acr` - le da al cluster
# permiso de pull sin necesitar una managed identity propia ni credenciales
# admin del registry.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
