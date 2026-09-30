terraform {
  required_version = ">= 1.10.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.0, < 6.0"
    }
  }
  # terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false # never hard-delete secrets on destroy
    }
  }
}

data "azurerm_client_config" "current" {}

variable "operator_cidrs" {
  description = "Office / VPN / CI egress CIDRs allowed to reach the API server and Key Vault."
  type        = list(string)
}

variable "admin_group_object_ids" {
  description = "Entra ID groups that get cluster-admin."
  type        = list(string)
  default     = []
}

module "aks" {
  source                   = "../../modules/aks"
  name                     = "demodev"
  location                 = "westeurope"
  tenant_id                = data.azurerm_client_config.current.tenant_id
  sku_tier                 = "Free"
  api_authorized_ip_ranges = var.operator_cidrs
  admin_group_object_ids   = var.admin_group_object_ids
  system_pool              = { vm_size = "Standard_D2s_v5", min_count = 1, max_count = 2 }
  user_pool                = { vm_size = "Standard_D4s_v5", min_count = 0, max_count = 4, spot = true } # dev runs on Spot
  tags = {
    environment = "dev"
    managed_by  = "terraform"
    repository  = "azure-aks-terraform"
  }
}

output "get_credentials" {
  description = "Command to fetch an Entra ID kubeconfig."
  value       = "az aks get-credentials -g ${module.aks.resource_group_name} -n ${module.aks.cluster_name} && kubelogin convert-kubeconfig -l azurecli"
}

output "acr_login_server" {
  description = "Registry login server."
  value       = module.aks.acr_login_server
}

output "workload_identity_client_id" {
  description = "Client id for the app service account annotation."
  value       = module.aks.workload_identity_client_id
}
