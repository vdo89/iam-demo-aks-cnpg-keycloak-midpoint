locals {
  tags = {
    project = "rws-iam-demo"
    owner   = "rws"
  }

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "${var.prefix}-rg"
}

resource "random_string" "sa_suffix" {
  length  = 6
  upper   = false
  special = false
}

data "azurerm_resource_group" "rg" {
  count = var.create_resource_group ? 0 : 1
  name  = local.resource_group_name
}

resource "azurerm_resource_group" "rg" {
  count    = var.create_resource_group ? 1 : 0
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  resource_group_location          = var.create_resource_group ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
  aks_default_node_max_surge_trim  = trimspace(var.aks_default_node_max_surge)
}

# Storage account for CNPG backups (Azure Blob)
resource "azurerm_storage_account" "sa" {
  name                            = "${var.prefix}sa${random_string.sa_suffix.result}"
  resource_group_name             = local.resource_group_name
  location                        = local.resource_group_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = local.tags
}

resource "azurerm_storage_container" "cnpg" {
  name                  = "cnpg-backups"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

# AKS (defaults sized for Keycloak + midPoint demo workloads)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.prefix}-aks"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  dns_prefix          = "${var.prefix}-aks"
  sku_tier            = var.aks_sku_tier

  default_node_pool {
    name       = "system"
    vm_size    = var.aks_default_node_vm_size
    node_count = var.aks_default_node_count
    os_sku     = "AzureLinux"
    # Required by the AzureRM provider when properties that force
    # a rotation (e.g. os_sku) are updated on the default node pool.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = local.aks_default_node_max_surge_trim
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Workload identity can be enabled later if you prefer (demo keeps secrets simple).
  # workload_identity_enabled = true

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  tags = local.tags
}
