output "user_pool_id" {
  description = "Employee user pool ID (for the add/remove-employee commands in the runbook)."
  value       = aws_cognito_user_pool.employees.id
}

output "client_id" {
  description = "The site's public app client ID. Not a secret: it ships in the site bundle."
  value       = aws_cognito_user_pool_client.site.id
}

output "issuer" {
  description = "OIDC issuer (authority) for the user pool."
  value       = "https://${aws_cognito_user_pool.employees.endpoint}"
}

output "login_domain" {
  description = "Hostname of the managed sign-in pages (and the passkey relying party)."
  value       = "${aws_cognito_user_pool_domain.employees.domain}.auth.${local.region}.amazoncognito.com"
}

output "api_url" {
  description = "Base URL of the employee API (GET <url>/me)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}
