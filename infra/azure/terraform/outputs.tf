output "resource_group" {
  value = local.resource_group_name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "storage_blob_endpoint" {
  value = azurerm_storage_account.sa.primary_blob_endpoint
}

output "ingress_public_ip" {
  value = azurerm_public_ip.ingress.ip_address
}

output "ingress_public_ip_name" {
  value = azurerm_public_ip.ingress.name
}
