# --- Protected employee API ---------------------------------------------------
#
# An HTTP API, separate from the public chat API: nothing here is reachable
# without a valid token from the employee user pool. API Gateway checks the
# token (signature, issuer, audience, expiry) before a Lambda ever runs.

resource "aws_apigatewayv2_api" "employees" {
  name          = var.name_prefix
  protocol_type = "HTTP"
  description   = "Employee-only API behind Cognito sign-in."

  cors_configuration {
    allow_origins = var.site_origins
    allow_methods = ["GET"]
    allow_headers = ["authorization"]
    max_age       = 3600
  }

  tags = var.tags
}

# Accepts the site client's ID tokens (their `aud` is the client ID).
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.employees.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = "https://${aws_cognito_user_pool.employees.endpoint}"
    audience = [aws_cognito_user_pool_client.site.id]
  }
}

resource "aws_apigatewayv2_integration" "me" {
  api_id                 = aws_apigatewayv2_api.employees.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.me.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "me" {
  api_id             = aws_apigatewayv2_api.employees.id
  route_key          = "GET /me"
  target             = "integrations/${aws_apigatewayv2_integration.me.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# Admin routes. The authorizer only proves the caller is a signed-in
# employee; the function itself requires the admins group (403 otherwise).
resource "aws_apigatewayv2_integration" "admin" {
  api_id                 = aws_apigatewayv2_api.employees.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.admin.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "admin" {
  for_each = toset(["GET /admin/usage", "GET /admin/conversations"])

  api_id             = aws_apigatewayv2_api.employees.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.admin.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# No access logs: HTTP API logging needs account-wide CloudWatch Logs
# delivery permissions for CI. The Lambda logs each call instead.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.employees.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  tags = var.tags
}
