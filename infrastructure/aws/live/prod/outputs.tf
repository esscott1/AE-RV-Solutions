output "site_url" {
  description = "Live URL for the production site."
  value       = module.amplify.branch_url
}

output "amplify_app_id" {
  description = "Amplify app ID, useful for AWS console links and CLI commands."
  value       = module.amplify.app_id
}

output "webhook_url" {
  description = "POST this URL to trigger a build. Run `terraform output -raw webhook_url` and store it as the AMPLIFY_WEBHOOK_URL GitHub Actions secret."
  value       = module.amplify.webhook_url
  sensitive   = true
}
