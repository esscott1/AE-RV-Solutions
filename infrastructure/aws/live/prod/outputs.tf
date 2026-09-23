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

output "domain_url" {
  description = "Live URL on the custom apex domain."
  value       = "https://${var.domain_name}"
}

output "www_url" {
  description = "Live URL on the www subdomain."
  value       = "https://www.${var.domain_name}"
}

output "name_servers" {
  description = "Route 53 nameservers for the zone. These must match the nameservers set at the GoDaddy registrar, or the domain stops resolving."
  value       = aws_route53_zone.primary.name_servers
}

output "chat_api_url" {
  description = "Chatbot API base URL (POST /chat, GET /chat/status)."
  value       = module.chatbot.chat_api_url
}

output "chat_api_key" {
  description = "Public usage-plan key the site sends as x-api-key. Put it in site/.env as PUBLIC_CHAT_API_KEY for local development."
  value       = module.chatbot.chat_api_key
}

output "chatbot_flag_parameter" {
  description = "SSM parameter holding the chatbot on/off switch."
  value       = module.chatbot.flag_parameter_name
}

output "kb_docs_bucket" {
  description = "Upload knowledge base documents here (S3 console), then run the 'Chatbot knowledge base sync' workflow."
  value       = module.chatbot.kb_docs_bucket
}

output "knowledge_base_id" {
  description = "Bedrock knowledge base ID for the chatbot."
  value       = module.chatbot.knowledge_base_id
}
