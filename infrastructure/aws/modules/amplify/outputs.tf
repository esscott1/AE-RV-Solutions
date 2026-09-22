output "app_id" {
  description = "Amplify app ID."
  value       = aws_amplify_app.this.id
}

output "default_domain" {
  description = "Default Amplify domain for the app, e.g. d1a2b3c4.amplifyapp.com."
  value       = aws_amplify_app.this.default_domain
}

output "branch_url" {
  description = "Full URL Amplify serves this branch on."
  value       = "https://${aws_amplify_branch.this.branch_name}.${aws_amplify_app.this.default_domain}"
}

output "webhook_url" {
  description = "POST this URL to trigger a build. Store as the AMPLIFY_WEBHOOK_URL GitHub Actions secret."
  value       = aws_amplify_webhook.deploy.url
  sensitive   = true
}

output "domain_association_arn" {
  description = "ARN of the custom domain association, or null when no domain is configured."
  value       = one(aws_amplify_domain_association.this[*].arn)
}
