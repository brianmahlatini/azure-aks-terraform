variable "name" {
  description = "Name prefix (lowercase letters and digits, 3-16 chars; ACR and Key Vault names derive from it)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,15}$", var.name))
    error_message = "name must be 3-16 lowercase letters/digits starting with a letter."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "tenant_id" {
  description = "Entra ID tenant for cluster RBAC and Key Vault."
  type        = string
}

variable "kubernetes_version" {
  description = "AKS minor version (patches roll automatically via the patch upgrade channel)."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "Free for dev; Standard gives the financially backed API server SLA for prod."
  type        = string
  default     = "Free"
  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "vnet_cidr" {
  description = "Address space for the VNet. With Azure CNI Overlay, pods do not consume VNet IPs."
  type        = string
  default     = "10.30.0.0/16"
}

variable "zones" {
  description = "Availability zones for node pools."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_pool" {
  description = "System node pool (CriticalAddonsOnly)."
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
  })
  default = { vm_size = "Standard_D2s_v5", min_count = 1, max_count = 3 }
  validation {
    condition     = var.system_pool.min_count >= 1 && var.system_pool.min_count <= var.system_pool.max_count
    error_message = "system_pool needs 1 <= min_count <= max_count."
  }
}

variable "user_pool" {
  description = "Workload node pool."
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
    spot      = bool
  })
  default = { vm_size = "Standard_D4s_v5", min_count = 1, max_count = 5, spot = false }
  validation {
    condition     = var.user_pool.min_count >= 0 && var.user_pool.min_count <= var.user_pool.max_count
    error_message = "user_pool needs 0 <= min_count <= max_count."
  }
}

variable "api_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the Kubernetes API. Empty means unrestricted, which is rejected unless allow_public_api is true."
  type        = list(string)
  default     = []
}

variable "allow_public_api" {
  description = "Explicit opt-in for an API server reachable from any IP (demo only)."
  type        = bool
  default     = false
}

variable "admin_group_object_ids" {
  description = "Entra ID groups granted cluster-admin through Azure RBAC."
  type        = list(string)
  default     = []
}

variable "workload_namespace" {
  description = "Namespace of the app service account that gets a federated workload identity."
  type        = string
  default     = "app"
}

variable "workload_service_account" {
  description = "Kubernetes service account name bound to the workload identity."
  type        = string
  default     = "app"
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "acr_sku" {
  description = "Container registry SKU. Premium adds zone redundancy, retention and private endpoints."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard or Premium."
  }
}

variable "private_cluster_enabled" {
  description = "Private API server endpoint (requires network line of sight, e.g. self-hosted runners or VPN)."
  type        = bool
  default     = false
}
