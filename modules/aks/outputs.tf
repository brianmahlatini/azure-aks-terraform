output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource group holding the platform."
  value       = azurerm_resource_group.this.name
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer for additional federated credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "acr_login_server" {
  description = "Registry to push images to."
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_uri" {
  description = "Key Vault URI for the CSI SecretProviderClass."
  value       = azurerm_key_vault.this.vault_uri
}

output "workload_identity_client_id" {
  description = "Annotate the service account with azure.workload.identity/client-id = this value."
  value       = azurerm_user_assigned_identity.workload.client_id
}
