output "default_host_name" {
  description = "Default hostname Azure serves this Static Web App on."
  value       = azurerm_static_web_app.this.default_host_name
}

output "resource_group_name" {
  description = "Resource group holding this app's resources."
  value       = azurerm_resource_group.this.name
}

output "api_key" {
  description = "Deployment token. Store as the AZURE_STATIC_WEB_APPS_API_TOKEN GitHub Actions secret."
  value       = azurerm_static_web_app.this.api_key
  sensitive   = true
}
