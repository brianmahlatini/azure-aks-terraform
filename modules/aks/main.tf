# AKS platform: private-by-default cluster with Entra ID RBAC (local accounts
# disabled), Azure CNI Overlay + Cilium network policy, workload identity for
# pods, ACR pull via the kubelet identity, Key Vault via the CSI driver, and
# Container Insights to Log Analytics.

locals {
  tags        = merge(var.tags, { module = "aks" })
  suffix      = substr(sha1("${var.name}-${var.location}"), 0, 6) # stable, globally-unique-ish suffix
  acr_name    = "${var.name}acr${local.suffix}"
  kv_name     = "${var.name}-kv-${local.suffix}"
  node_subnet = cidrsubnet(var.vnet_cidr, 4, 0) # /20: 4096 node IPs; pods use the overlay CIDR
}

resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = length(var.api_authorized_ip_ranges) > 0 || var.allow_public_api
      error_message = "Set api_authorized_ip_ranges, or explicitly set allow_public_api = true."
    }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.node_subnet]
}

# Subnet NSG: AKS still manages its own node-level NSG; this one gives the
# platform team a place for org-wide rules and satisfies subnet baselines.
resource "azurerm_network_security_group" "nodes" {
  name                = "nsg-${var.name}-aks-nodes"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_233:Zone redundancy, geo-replication, dedicated data endpoints, content trust, quarantine and retention are Premium-SKU features; acr_sku = "Premium" for prod
  #checkov:skip=CKV_AZURE_237:Premium-only (see above)
  #checkov:skip=CKV_AZURE_164:Premium-only (see above); image signing is enforced in CI with cosign instead
  #checkov:skip=CKV_AZURE_165:Premium-only (see above)
  #checkov:skip=CKV_AZURE_166:Premium-only (see above); images are scanned with Trivy in CI before push
  #checkov:skip=CKV_AZURE_167:Premium-only (see above)
  #checkov:skip=CKV_AZURE_139:CI runners push over the public endpoint; use a private endpoint with self-hosted runners
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = var.acr_sku
  admin_enabled                 = false # pulls use managed identity, never a shared password
  public_network_access_enabled = true
  tags                          = local.tags
}

# User-assigned identities instead of system-assigned: they exist before the
# cluster, so role assignments (ACR pull, subnet join) are in place when the
# first node boots, and they survive a cluster rebuild unchanged.
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-${var.name}-kubelet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# The control plane assigns the kubelet identity to nodes...
resource "azurerm_role_assignment" "cp_identity_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
}

# ...and joins nodes / load balancers to our own subnet.
resource "azurerm_role_assignment" "cp_network" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_117:OS disks are ephemeral (no persistent OS data); a CMK disk encryption set is an org-level choice
  #checkov:skip=CKV_AZURE_170:sku_tier is a variable; Standard is used in prod
  #checkov:skip=CKV_AZURE_6:Authorized IP ranges are required by the guardrails precondition unless explicitly opted out
  #checkov:skip=CKV_AZURE_115:private_cluster_enabled is a variable; public API + authorized IPs keeps the demo reachable from CI
  name                      = "aks-${var.name}"
  location                  = azurerm_resource_group.this.location
  resource_group_name       = azurerm_resource_group.this.name
  dns_prefix                = var.name
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  automatic_upgrade_channel = "patch"     # security patches without surprise minor upgrades
  node_os_upgrade_channel   = "NodeImage" # weekly patched node images
  local_account_disabled    = true        # no static admin kubeconfig; Entra ID only
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true
  private_cluster_enabled   = var.private_cluster_enabled

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_pool.vm_size
    vnet_subnet_id               = azurerm_subnet.nodes.id
    zones                        = var.zones
    auto_scaling_enabled         = true
    min_count                    = var.system_pool.min_count
    max_count                    = var.system_pool.max_count
    only_critical_addons_enabled = true # keep app pods off the system pool
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = 64
    host_encryption_enabled      = true # encrypts temp disks and caches at the VM host
    max_pods                     = 110
    temporary_name_for_rotation  = "systemtmp"
    upgrade_settings {
      max_surge = "33%"
    }
    tags = local.tags
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  kubelet_identity {
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
  }

  # Explicit node pools managed here; "Auto" would hand provisioning to
  # Node Auto Provisioning (Karpenter), a reasonable later step.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_authorized_ip_ranges
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Sunday"
    start_time  = "02:00"
    duration    = 4
    utc_offset  = "+00:00"
  }

  lifecycle {
    # The autoscaler owns node counts.
    ignore_changes = [default_node_pool[0].node_count]
  }

  depends_on = [terraform_data.guardrails, azurerm_role_assignment.cp_identity_operator, azurerm_role_assignment.cp_network]
  tags       = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                    = "user"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.this.id
  vm_size                 = var.user_pool.vm_size
  vnet_subnet_id          = azurerm_subnet.nodes.id
  zones                   = var.zones
  mode                    = "User"
  auto_scaling_enabled    = true
  min_count               = var.user_pool.min_count
  max_count               = var.user_pool.max_count
  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = 64
  host_encryption_enabled = true
  max_pods                = 110
  priority                = var.user_pool.spot ? "Spot" : "Regular"
  eviction_policy         = var.user_pool.spot ? "Delete" : null
  spot_max_price          = var.user_pool.spot ? -1 : null # pay up to on-demand, never be outbid on price
  node_taints             = var.user_pool.spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []
  node_labels             = { workload = "general" }

  dynamic "upgrade_settings" {
    for_each = var.user_pool.spot ? [] : [1] # surge settings are not supported on spot pools
    content {
      max_surge = "33%"
    }
  }

  lifecycle {
    ignore_changes = [node_count]
  }
  tags = local.tags
}

# Kubelet pulls images from ACR with its managed identity.
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.kubelet.principal_id
  skip_service_principal_aad_check = true
}

# ----------------------------------------------------------- Key Vault
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_189:Public endpoint is locked to authorized IPs with default Deny; use a private endpoint with private_cluster_enabled
  #checkov:skip=CKV2_AZURE_32:See CKV_AZURE_189
  name                          = local.kv_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true # Azure RBAC instead of legacy access policies
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.api_authorized_ip_ranges
  }
  tags = local.tags
}

# ----------------------------------------------------- workload identity
# The app's service account exchanges its projected token for an Entra ID
# token for this identity: no client secrets anywhere in the cluster.
resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-${var.name}-workload"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "workload" {
  name                      = "fic-${var.workload_namespace}-${var.workload_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.workload_namespace}:${var.workload_service_account}"
}

resource "azurerm_role_assignment" "workload_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User" # read secrets only; no keys, certs or management
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}
