# Azure CNI FLAT (sin network_plugin_mode = "overlay") a proposito: Virtual
# Nodes no es compatible con Azure CNI Overlay (confirmado contra la doc de
# Microsoft). Esto significa que tanto el nodo real como los pods en
# Virtual Nodes reciben IPs reales y ruteables de la VNet, no de un rango
# overlay separado - por eso snet-aks-virtual-nodes esta sizeado como /24
# completo en vez de algo mas chico.
resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_171:sin canal de auto-upgrade a proposito - cluster de corta vida, sin gestion continua de versiones
  #checkov:skip=CKV_AZURE_172:no usamos Secrets Store CSI Driver en este proyecto - el cert va directo a un Kubernetes Secret (ver acme.tf)
  #checkov:skip=CKV_AZURE_232:only_critical_addons_enabled rompe AGIC (bug conocido: el pod de AGIC no arranca) - no lo activamos a proposito
  #checkov:skip=CKV_AZURE_7:sin Network Policy - una sola app en el cluster, no hay nada que segmentar
  #checkov:skip=CKV_AZURE_168:umbral de 50 pods/nodo no aplica a un cluster de 1 nodo con un solo hello-world
  #checkov:skip=CKV_AZURE_141:deshabilitar cuentas locales requiere Azure AD RBAC integration - sin eso configurado, perderiamos acceso via kubectl. Complejidad no justificada en este proyecto
  #checkov:skip=CKV_AZURE_170:Free SKU a proposito - sin SLA pago, no justificado el costo para este proyecto (ver variables.tf)
  #checkov:skip=CKV_AZURE_226:no elegimos ephemeral OS disk a proposito - simplicidad, sin datos persistentes que proteger en el hello-world
  #checkov:skip=CKV_AZURE_227:mismo motivo que arriba
  #checkov:skip=CKV_AZURE_115:cluster publico a proposito - simplifica el acceso a kubectl, no apto para produccion
  #checkov:skip=CKV_AZURE_6:sin restriccion de IPs al API server - simplifica el acceso
  #checkov:skip=CKV_AZURE_117:disk encryption set con customer-managed key no justificado - sin datos sensibles en este proyecto
  #checkov:skip=CKV_AZURE_116:Azure Policy add-on es gobernanza a nivel organizacion - no aplica a un solo cluster
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  default_node_pool {
    name           = "system"
    vm_size        = var.default_node_pool_vm_size
    node_count     = var.default_node_pool_node_count
    vnet_subnet_id = var.network_aks_subnet_id

    upgrade_settings {
      max_surge = "10%"
    }

    tags = local.tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Requerido explicitamente por azurerm >= 5.x. mode = "Manual" = sin Node
  # Autoprovisioning (Karpenter) - decidimos no usarlo en este proyecto (ver
  # CLAUDE.md), el unico node pool real es fijo y chico.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    # Sin network_plugin_mode: flat, no overlay (ver comentario arriba).
    # Sin pod_cidr: en modo flat los pods toman IP directo del subnet del
    # nodo (snet-aks) - pod_cidr solo aplica a kubenet/overlay.
    # service_cidr/dns_service_ip: el default de AKS es 10.0.0.0/16, que
    # colisiona con la VNet compartida (vnet-jalcalaroot, tambien 10.0.0.0/16)
    # - "ServiceCidrOverlapExistingSubnetsCidr" al aplicar sin esto. El
    # service CIDR es puramente virtual (nunca se rutea en la VNet), asi que
    # cualquier rango fuera de 10.0.0.0/16 sirve.
    service_cidr   = "172.16.0.0/16"
    dns_service_ip = "172.16.0.10"
  }

  # Virtual Nodes (ACI-backed) - el homologo de un Fargate Profile de EKS.
  # AKS delega el subnet indicado a Microsoft.ContainerInstance/
  # containerGroups (ya lo delegamos nosotros mismos en
  # jalcalaroot-azure-bootstrap para que quede en Terraform, no fuera de
  # banda). subnet_name es el NOMBRE del subnet, no el ID completo.
  aci_connector_linux {
    subnet_name = local.aks_virtual_nodes_subnet_name
  }

  # AGIC (Application Gateway Ingress Controller) como addon administrado -
  # gateway_id apunta al Application Gateway "bring your own" de
  # app_gateway.tf. AKS SI crea automaticamente la managed identity de AGIC,
  # pero NO le da ningun permiso sobre el Application Gateway/subnet/resource
  # group - eso hay que armarlo a mano (ver los tres azurerm_role_assignment
  # mas abajo, agregados despues de que el addon fallara en runtime sin
  # ellos). Este comentario decia lo contrario hasta que se encontro la
  # contradiccion con el codigo real de este mismo archivo.
  ingress_application_gateway {
    gateway_id = azurerm_application_gateway.this.id
  }

  # Container Insights, reutilizando el Log Analytics Workspace compartido -
  # mismo patron que azure-container-apps.
  oms_agent {
    log_analytics_workspace_id = var.network_log_analytics_workspace_id
  }

  tags = local.tags
}

# El nombre del subnet de virtual nodes se deriva del ID (aci_connector_linux
# pide el NOMBRE, no el ID completo).
locals {
  aks_virtual_nodes_subnet_name = element(
    split("/", var.network_aks_virtual_nodes_subnet_id),
    length(split("/", var.network_aks_virtual_nodes_subnet_id)) - 1
  )
}

# AKS crea automaticamente las managed identities de los addons (ACI
# Connector, AGIC), pero NO les da ningun permiso sobre los recursos que
# necesitan gestionar - eso es responsabilidad de quien despliega, confirmado
# empiricamente con "bring your own" Application Gateway/subnet (ambos
# fallaron en runtime con AuthorizationFailed hasta agregar esto a mano).

# ACI Connector necesita leer y unirse al subnet delegado. Como el subnet
# vive en otro resource group (jalcalaroot, no rg-aks-cluster), el fix
# tiene que ser explicito aca.
resource "azurerm_role_assignment" "aci_connector_virtual_nodes_subnet" {
  scope                = var.network_aks_virtual_nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.aci_connector_linux[0].connector_identity[0].object_id
}

# AGIC necesita Contributor sobre el Application Gateway (para reconfigurar
# listeners/reglas/backends) y Reader sobre su resource group.
resource "azurerm_role_assignment" "agic_app_gateway_contributor" {
  scope                = azurerm_application_gateway.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_role_assignment" "agic_resource_group_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# AGIC tambien necesita join/action sobre el subnet del Application Gateway
# para poder reconfigurar el gateway - mismo motivo cross-resource-group que
# el subnet de virtual nodes arriba (ApplicationGatewayInsufficientPermissionOnSubnet).
resource "azurerm_role_assignment" "agic_appgw_subnet_network_contributor" {
  scope                = var.network_appgw_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}
