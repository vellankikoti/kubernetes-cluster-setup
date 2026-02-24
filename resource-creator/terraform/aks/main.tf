locals {
  env_config = {
    dev     = { cidr = "10.40.0.0/16", min = 1, max = 6 }
    qa      = { cidr = "10.41.0.0/16", min = 1, max = 6 }
    staging = { cidr = "10.42.0.0/16", min = 2, max = 10 }
    prod    = { cidr = "10.43.0.0/16", min = 3, max = 20 }
  }
  selected = { for e in var.environments : e => local.env_config[e] }
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  for_each = local.selected
  name     = "rg-${var.base_name}-${each.key}-aks"
  location = var.region
  tags     = merge(var.tags, { env = each.key, tenant_id = data.azurerm_client_config.current.tenant_id })
}

resource "azurerm_virtual_network" "vnet" {
  for_each            = local.selected
  name                = "vnet-${var.base_name}-${each.key}"
  address_space       = [each.value.cidr]
  location            = var.region
  resource_group_name = azurerm_resource_group.rg[each.key].name
}

resource "azurerm_subnet" "aks" {
  for_each             = local.selected
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.rg[each.key].name
  virtual_network_name = azurerm_virtual_network.vnet[each.key].name
  address_prefixes     = [cidrsubnet(each.value.cidr, 4, 0)]
}

resource "azurerm_log_analytics_workspace" "law" {
  for_each            = local.selected
  name                = "law-${var.base_name}-${each.key}"
  location            = var.region
  resource_group_name = azurerm_resource_group.rg[each.key].name
  sku                 = "PerGB2018"
  retention_in_days   = each.key == "prod" ? 30 : 14
}

resource "azurerm_kubernetes_cluster" "aks" {
  for_each            = local.selected
  name                = "${var.base_name}-${each.key}-aks"
  location            = var.region
  resource_group_name = azurerm_resource_group.rg[each.key].name
  dns_prefix          = "${var.base_name}-${each.key}"
  kubernetes_version  = var.cluster_version
  private_cluster_enabled = true
  oidc_issuer_enabled     = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = each.key == "prod" ? "Standard_D4s_v5" : "Standard_D2s_v5"
    vnet_subnet_id       = azurerm_subnet.aks[each.key].id
    auto_scaling_enabled = true
    min_count            = each.value.min
    max_count            = each.value.max
    zones                = ["1", "2", "3"]
    os_disk_type         = "Managed"
    os_disk_size_gb      = 128
    only_critical_addons_enabled = true
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  azure_policy_enabled             = true
  role_based_access_control_enabled = true
  sku_tier                         = each.key == "prod" ? "Standard" : "Free"

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law[each.key].id
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
  }

  tags = merge(var.tags, { env = each.key, tenant_id = data.azurerm_client_config.current.tenant_id })
}

resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  for_each              = local.selected
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
  vm_size               = "Standard_D4ps_v5"
  auto_scaling_enabled  = true
  min_count             = each.key == "prod" ? 2 : 1
  max_count             = each.value.max * 2
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  zones                 = ["1", "2", "3"]
  node_labels = {
    workload = "stateless"
  }
  node_taints = ["spot=true:NoSchedule"]
  vnet_subnet_id = azurerm_subnet.aks[each.key].id
  upgrade_settings {
    max_surge = "33%"
  }
}
