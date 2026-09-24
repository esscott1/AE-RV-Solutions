data "aws_region" "current" {}

locals {
  region        = data.aws_region.current.region
  callback_urls = [for origin in var.site_origins : "${origin}/employees/"]
}

# --- User pool ----------------------------------------------------------------

# Employees only: there's no self sign-up, and every account is created by an
# admin (runbook in infrastructure/README.md → Employees). Their email
# addresses live only here, never in this public repo.
#
# Sign-in is a password or a passkey. Email sign-in codes would need SES, and
# Cognito's built-in email (50 a day) is plenty for invites and password
# resets. A passkey can't count as MFA until the AWS provider exposes
# FactorConfiguration, so MFA is OPTIONAL and the runbook has every employee
# enroll an authenticator app. Change to "ON" once the provider supports it.
resource "aws_cognito_user_pool" "employees" {
  name                     = var.name_prefix
  user_pool_tier           = "ESSENTIALS"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"
  mfa_configuration        = "OPTIONAL"

  username_configuration {
    case_sensitive = false
  }

  sign_in_policy {
    allowed_first_auth_factors = ["PASSWORD", "WEB_AUTHN"]
  }

  # The relying party ID defaults to the prefix domain. Pin it before adding a
  # custom domain, or existing passkeys stop working.
  web_authn_configuration {
    user_verification = "required"
  }

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # An email change only takes effect once the new address is verified.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  # Cognito requires an SMS invite template (at least 6 characters, with
  # {username} and {####}) even though this pool never sends texts: leaving it
  # out makes the provider send an empty one, which CreateUserPool rejects.
  admin_create_user_config {
    allow_admin_create_user_only = true

    invite_message_template {
      email_subject = "Your A&E RV Solutions employee account"
      email_message = "You've been added to the A&E RV Solutions employee site. Sign in at https://aervsolutions.com/employees/ with your email ({username}) and this temporary password: {####}<br><br>It expires in 7 days. You'll choose your own password, set up an authenticator app, and can then add a passkey."
      sms_message   = "A&E RV Solutions employee sign-in: username {username}, temporary password {####}"
    }
  }

  tags = var.tags

  # Deleting the pool deletes every employee account and passkey. To remove
  # it deliberately, drop this (and deletion_protection) in its own PR first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.employees.id
  description  = "Can open the Admin page (AI usage, knowledge approvals)."
  precedence   = 1
}

# --- Sign-in pages (managed login) ------------------------------------------

resource "aws_cognito_user_pool_domain" "employees" {
  domain                = var.domain_prefix
  user_pool_id          = aws_cognito_user_pool.employees.id
  managed_login_version = 2
}

# Public client for the site: no secret (it would ship in the browser bundle),
# authorization code flow with PKCE.
#
# aws.cognito.signin.user.admin lets a signed-in employee's access token call
# Cognito's self-service APIs for their own account only (e.g.
# AssociateSoftwareToken to set up an authenticator app, since MFA is
# OPTIONAL and managed login doesn't prompt for it). It grants nothing over
# other users; admin actions still need IAM.
resource "aws_cognito_user_pool_client" "site" {
  name         = "${var.name_prefix}-site"
  user_pool_id = aws_cognito_user_pool.employees.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile", "aws.cognito.signin.user.admin"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = local.callback_urls
  logout_urls                          = local.callback_urls

  explicit_auth_flows = [
    "ALLOW_USER_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 12

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}

# Managed login shows no pages for a client until it has a branding style,
# and the API doesn't create one. These are Cognito's default look.
resource "aws_cognito_managed_login_branding" "site" {
  client_id                   = aws_cognito_user_pool_client.site.id
  user_pool_id                = aws_cognito_user_pool.employees.id
  use_cognito_provided_values = true
}
