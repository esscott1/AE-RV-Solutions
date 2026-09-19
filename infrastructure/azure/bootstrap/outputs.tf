output "resource_group_name" {
  description = "Resource group holding the Terraform state storage account. Use as `resource_group_name` in live/*/backend.hcl."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Storage account holding Terraform remote state. Use as `storage_account_name` in live/*/backend.hcl."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Blob container holding Terraform state files. Use as `container_name` in live/*/backend.hcl."
  value       = azurerm_storage_container.tfstate.name
}
