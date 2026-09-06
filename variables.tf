variable "subscription_id" {
  description = "Subscription ID de Azure - requerido explicitamente por el provider azurerm >= 4.0. Sin default: TF_VAR_subscription_id (NO ARM_SUBSCRIPTION_ID)."
  type        = string
}

variable "location" {
  description = "Azure region - debe coincidir con la region de la VNet compartida (vnet-jalcalaroot vive en eastus)"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group dedicado a este proyecto"
  type        = string
  default     = "rg-aks-containers-poc"
}

variable "environment" {
  type    = string
  default = "poc"
}

variable "owner" {
  type = string
}

variable "project" {
  type    = string
  default = "aks-containers-poc"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ============================================================================
# Red compartida (jalcalaroot-azure-bootstrap) - valores copiados a mano,
# sin terraform_remote_state, mismo patron que azure-container-apps-poc.
# ============================================================================

variable "network_aks_subnet_id" {
  description = "ID del subnet snet-aks (node pool real del cluster)"
  type        = string
}

variable "network_aks_virtual_nodes_subnet_id" {
  description = "ID del subnet snet-aks-virtual-nodes (delegado a Microsoft.ContainerInstance/containerGroups, para los pods ACI-backed)"
  type        = string
}

variable "network_appgw_subnet_id" {
  description = "ID del subnet snet-appgw, donde vive el Application Gateway que AGIC va a gestionar"
  type        = string
}

variable "network_log_analytics_workspace_id" {
  description = "ID del Log Analytics Workspace compartido - se reutiliza para Container Insights"
  type        = string
}

# ============================================================================
# AKS
# ============================================================================

variable "cluster_name" {
  type    = string
  default = "aks-containers-poc"
}

variable "dns_prefix" {
  type    = string
  default = "aks-containers-poc"
}

variable "kubernetes_version" {
  description = "Version de Kubernetes. null = la version default soportada por AKS al momento del apply."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "SKU del control plane (Free, Standard, Premium). Free alcanza para una POC."
  type        = string
  default     = "Free"
}

variable "default_node_pool_vm_size" {
  description = "SKU de VM para el (unico) nodo real del cluster. El hello-world corre en Virtual Nodes, no aca - este nodo solo hostea componentes de sistema. D2s_v5 no esta habilitado en esta suscripcion en eastus (solo v7 y algunas series especificas, confirmado por el error 400 de AKS) - se usa v7."
  type        = string
  default     = "Standard_D2s_v7"
}

variable "default_node_pool_node_count" {
  description = "Cantidad de nodos reales que hostean los componentes de sistema (CoreDNS, kube-proxy, CSI drivers, Azure CNS, AGIC, ACI connector) - estos NO pueden correr en Virtual Nodes porque necesitan hostNetwork/acceso al host, algo que ACI no provee. 2 (no 3) porque la suscripcion tiene solo 4 vCPU de cuota TOTAL en la region - a 2 vCPU por nodo, 2 nodos es el maximo posible sin pedir un aumento de cuota a Azure."
  type        = number
  default     = 2
}

# ============================================================================
# ACR
# ============================================================================

variable "acr_name" {
  description = "Nombre del Azure Container Registry - debe ser unico globalmente"
  type        = string
  default     = "acrakscontainerspoc"
}

# ============================================================================
# DNS + certificado
# ============================================================================

variable "dns_zone_name" {
  description = "Azure DNS Zone EXISTENTE donde se agrega el registro de este proyecto"
  type        = string
  default     = "azure.jalcalaroot.com"
}

variable "dns_zone_resource_group_name" {
  description = "Resource group de la DNS Zone existente"
  type        = string
  default     = "jalcalaroot"
}

variable "dns_record_name" {
  description = "Nombre del registro A -> FQDN final = <dns_record_name>.<dns_zone_name>"
  type        = string
  default     = "aks"
}

variable "acme_email" {
  description = "Email para la cuenta ACME de Let's Encrypt. Sin default."
  type        = string
}

variable "acme_server_url" {
  description = "Endpoint del directorio ACME. Usa el de staging mientras iteras (5 duplicados/semana en produccion)."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

# ============================================================================
# Application Gateway
# ============================================================================

variable "app_gateway_name" {
  type    = string
  default = "appgw-aks-containers-poc"
}

variable "app_gateway_sku_capacity" {
  type    = number
  default = 1
}
