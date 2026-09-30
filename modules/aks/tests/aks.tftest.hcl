# Offline unit tests with a mocked azurerm provider. Resource ids are given
# valid ARM shapes because the provider validates id arguments at plan time.
mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-aks-nodes" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test" }
  }
  mock_resource "azurerm_container_registry" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ContainerRegistry/registries/testacr" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/test-kv" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"
      principal_id = "11111111-1111-1111-1111-111111111111"
      client_id    = "22222222-2222-2222-2222-222222222222"
    }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      oidc_issuer_url = "https://oidc.example.test/00000000/"
    }
  }
}

variables {
  name                     = "demo"
  tenant_id                = "00000000-0000-0000-0000-000000000000"
  api_authorized_ip_ranges = ["203.0.113.0/24"]
}

run "cluster_is_hardened" {
  command = apply

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "Local (static) admin accounts must be disabled."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    error_message = "Azure RBAC must govern cluster access."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.oidc_issuer_enabled && azurerm_kubernetes_cluster.this.workload_identity_enabled
    error_message = "Workload identity requires the OIDC issuer and the workload identity add-on."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.api_server_access_profile[0].authorized_ip_ranges == toset(["203.0.113.0/24"])
    error_message = "API server must be restricted to authorized ranges."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.automatic_upgrade_channel == "patch"
    error_message = "Clusters should auto-apply patch releases."
  }
}

run "overlay_networking_with_cilium" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay"
    error_message = "Use Azure CNI Overlay so pods don't consume VNet addresses."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_policy == "cilium"
    error_message = "NetworkPolicy enforcement must be enabled (Cilium)."
  }
  assert {
    condition     = one(azurerm_subnet.nodes.address_prefixes) == "10.30.0.0/20"
    error_message = "Node subnet should be the first /20 of the VNet."
  }
}

run "system_pool_isolated_and_zonal" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled
    error_message = "App pods must not schedule on the system pool."
  }
  assert {
    condition     = length(azurerm_kubernetes_cluster.this.default_node_pool[0].zones) == 3
    error_message = "System pool should span three zones."
  }
}

run "registry_and_pull_identity" {
  command = apply

  assert {
    condition     = azurerm_container_registry.this.admin_enabled == false
    error_message = "ACR admin user must be disabled."
  }
  assert {
    condition     = azurerm_role_assignment.acr_pull.principal_id == azurerm_user_assigned_identity.kubelet.principal_id && azurerm_kubernetes_cluster.this.kubelet_identity[0].user_assigned_identity_id == azurerm_user_assigned_identity.kubelet.id
    error_message = "AcrPull must be granted to the kubelet identity."
  }
  assert {
    condition     = azurerm_role_assignment.acr_pull.role_definition_name == "AcrPull"
    error_message = "Kubelet should get AcrPull only."
  }
}

run "control_plane_can_manage_kubelet_identity" {
  command = apply

  assert {
    condition     = azurerm_role_assignment.cp_identity_operator.scope == azurerm_user_assigned_identity.kubelet.id
    error_message = "Control plane needs Managed Identity Operator on the kubelet identity."
  }
  assert {
    condition     = azurerm_role_assignment.cp_network.scope == azurerm_subnet.nodes.id
    error_message = "Control plane needs Network Contributor on the node subnet only."
  }
}

run "workload_identity_wiring" {
  command = apply

  assert {
    condition     = azurerm_federated_identity_credential.workload.subject == "system:serviceaccount:app:app"
    error_message = "Federated credential subject must match the app service account."
  }
  assert {
    condition     = azurerm_federated_identity_credential.workload.issuer == azurerm_kubernetes_cluster.this.oidc_issuer_url
    error_message = "Federated credential must trust this cluster's OIDC issuer."
  }
  assert {
    condition     = azurerm_role_assignment.workload_secrets.role_definition_name == "Key Vault Secrets User"
    error_message = "Workload should only read secrets."
  }
}

run "key_vault_protected" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled && azurerm_key_vault.this.purge_protection_enabled
    error_message = "Key Vault needs RBAC authorization and purge protection."
  }
  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny"
    error_message = "Key Vault network default must be Deny."
  }
}

run "spot_user_pool" {
  command = plan
  variables {
    user_pool = { vm_size = "Standard_D4s_v5", min_count = 0, max_count = 10, spot = true }
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.user.priority == "Spot"
    error_message = "spot = true should create a Spot pool."
  }
  assert {
    condition     = contains(azurerm_kubernetes_cluster_node_pool.user.node_taints, "kubernetes.azure.com/scalesetpriority=spot:NoSchedule")
    error_message = "Spot pools must be tainted so only tolerant workloads land there."
  }
}

run "regular_user_pool_by_default" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.user.priority == "Regular" && length(azurerm_kubernetes_cluster_node_pool.user.node_taints) == 0
    error_message = "Default user pool should be regular priority with no taints."
  }
}

run "rejects_open_api_server" {
  command = plan
  variables {
    api_authorized_ip_ranges = []
  }
  expect_failures = [terraform_data.guardrails]
}

run "allows_open_api_with_explicit_opt_in" {
  command = plan
  variables {
    api_authorized_ip_ranges = []
    allow_public_api         = true
  }
}

run "rejects_bad_name" {
  command = plan
  variables {
    name = "Bad_Name"
  }
  expect_failures = [var.name]
}
