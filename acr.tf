# Migrado a Azure Verified Module el 2026-09-28 - ver
# jalcalaroot-azure-bootstrap/CLAUDE.md "Dev VNet" para el contexto completo
# de la decision (todo lo que se construya en Azure de aca en adelante usa
# AVM donde exista un modulo real). Basic SKU, admin user deshabilitado - el
# pull lo hace el cluster via su kubelet identity (ver el role assignment
# abajo), no con credenciales admin embebidas. Sin cambios de comportamiento
# respecto al recurso crudo que reemplaza.
#
# Gotcha real de esta AVM: su default de sku es "Premium", no "Basic" -
# confirmado contra la doc del modulo. Omitir sku silenciosamente
# aprovisionaria Premium (costo real) en vez de mantener Basic.
module "acr" {
  #checkov:skip=CKV_TF_1: pinned por version semver del Terraform Registry (no un git tag movible) - Azure Verified Module oficial de Microsoft, versiones inmutables. Mismo criterio ya documentado en jalcalaroot-azure-bootstrap/network.tf.
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.8.0"

  name                = var.acr_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags

  # Default del modulo es true, pero zone redundancy solo es valido con
  # Premium SKU - "The Premium SKU is required if zone redundancy is
  # enabled", error real de precondicion del modulo, no adivinado.
  zone_redundancy_enabled = false

  enable_telemetry = false

  #checkov:skip=CKV_AZURE_164:content trust requiere Premium SKU - no justificado para este proyecto
  #checkov:skip=CKV_AZURE_139:acceso publico intencional - Basic SKU no soporta Private Endpoint de todas formas
  #checkov:skip=CKV_AZURE_165:geo-replicacion requiere Premium SKU - una sola region en este proyecto
  #checkov:skip=CKV_AZURE_233:zone redundancy requiere Premium SKU
  #checkov:skip=CKV_AZURE_167:retention policy requiere Premium SKU - una sola imagen (hello-world:latest) en este proyecto
  #checkov:skip=CKV_AZURE_166:quarantine/scanning requiere Premium SKU
  #checkov:skip=CKV_AZURE_237:dedicated data endpoints requiere Premium SKU
  #checkov:skip=CKV_AZURE_163:vulnerability scanning requiere Premium SKU
}

# Equivalente Terraform de `az aks update --attach-acr`. Recurso crudo, no
# la variable role_assignments (top-level) que expone esta AVM: esa
# variable no tiene NINGUN ejemplo de uso real en la doc del modulo (todos
# los ejemplos oficiales usan un azurerm_role_assignment separado, igual que
# esto) - se prefiere el patron ya probado en vez de un campo sin cobertura
# de ejemplos.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = module.acr.resource_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
