variable "subscription_id" {
  description = "Subscription ID de Azure - requerido explicitamente por el provider azurerm >= 4.0. Sin default a proposito: pasarlo via -var, un .tfvars gitignoreado, o TF_VAR_subscription_id (NO usar ARM_SUBSCRIPTION_ID, el provider no lo lee)."
  type        = string
}
