locals {
  tags = {
    project = "rws-iam-demo"
    owner   = "rws"
  }
}

resource "random_string" "sa_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

# Storage account for CNPG backups (Azure Blob)
resource "azurerm_storage_account" "sa" {
  name                            = "${var.prefix}sa${random_string.sa_suffix.result}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
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
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.prefix}-aks"

  default_node_pool {
    name       = "system"
    vm_size    = var.aks_default_node_vm_size
    node_count = var.aks_default_node_count
    os_sku     = "AzureLinux"
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
