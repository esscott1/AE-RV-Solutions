output "site_url" {
  description = "Live URL for the production site."
  value       = "https://${module.static_web_app.default_host_name}"
}

output "resource_group_name" {
  description = "Resource group holding the app's resources, useful for Azure portal/CLI lookups."
  value       = module.static_web_app.resource_group_name
}

output "deployment_token" {
  description = "Run `terraform output -raw deployment_token` and store it as the AZURE_STATIC_WEB_APPS_API_TOKEN GitHub Actions secret."
  value       = module.static_web_app.api_key
  sensitive   = true
}
