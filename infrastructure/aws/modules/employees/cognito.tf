data "aws_region" "current" {}

locals {
  region        = data.aws_region.current.region
  callback_urls = [for origin in var.site_origins : "${origin}/employees/"]

  # The pool's MFA settings, applied by terraform_data.mfa_config (see there
  # for why not by the pool resource). Change them here.
  mfa = {
    configuration     = "ON"
    totp_enabled      = true
    user_verification = "required"
    # A passkey with user verification counts as both factors. With
    # SINGLE_FACTOR, Cognito never offers passkey sign-in to a user with MFA.
    passkey_factor = "MULTI_FACTOR_WITH_USER_VERIFICATION"
  }
}

# --- User pool ----------------------------------------------------------------

# Employees only: there's no self sign-up, and every account is created by an
# admin (runbook in infrastructure/README.md → Employees). Their email
# addresses live only here, never in this public repo.
#
# Sign-in is a password or a passkey. Email sign-in codes would need SES, and
# Cognito's built-in email (50 a day) is plenty for invites and password
# resets. MFA is required: a password sign-in also needs an authenticator-app
# code, and a passkey (with user verification) counts as both factors. The
# MFA settings are applied by terraform_data.mfa_config below, not by this
# resource; see there.
resource "aws_cognito_user_pool" "employees" {
  name                     = var.name_prefix
  user_pool_tier           = "ESSENTIALS"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"
  # Create-time values only. After creation, terraform_data.mfa_config owns
  # these three settings (ignore_changes below). The real values are in
  # local.mfa.
  mfa_configuration = "OPTIONAL"

  username_configuration {
    case_sensitive = false
  }

  sign_in_policy {
    allowed_first_auth_factors = ["PASSWORD", "WEB_AUTHN"]
  }

  # The relying party ID defaults to the prefix domain. Pin it (in
  # terraform_data.mfa_config) before adding a custom domain, or existing
  # passkeys stop working.
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

  lifecycle {
    # Deleting the pool deletes every employee account and passkey. To remove
    # it deliberately, drop this (and deletion_protection) in its own PR
    # first.
    prevent_destroy = true

    # Owned by terraform_data.mfa_config. If the provider changed any of
    # these, it would send the passkey settings without FactorConfiguration,
    # which Cognito rejects while MFA is ON.
    ignore_changes = [mfa_configuration, software_token_mfa_configuration, web_authn_configuration]
  }
}

# The pool's MFA configuration: MFA ON, authenticator apps, and passkeys that
# count as both factors (FactorConfiguration).
#
# Why here and not on the pool resource: AWS provider 6.66 has no argument
# for FactorConfiguration, and whenever it sets the MFA configuration it
# omits the field, which Cognito treats as SINGLE_FACTOR. Cognito rejects
# SINGLE_FACTOR while MFA is ON and passkeys are allowed, so the provider
# can't set MFA ON at all. Instead, the apply sets the whole configuration
# with the AWS CLI, from local.mfa, and the pool ignores those settings.
#
# It still only changes through a reviewed Terraform apply: it reruns when
# local.mfa changes or the pool is replaced. Terraform can't read the live
# values back, so check them with
#   aws cognito-idp get-user-pool-mfa-config --user-pool-id <id>
# The CLI is called directly (no shell), so it runs the same in CI and on
# Windows; local applies need AWS_PROFILE set. Replace this with the provider
# argument once it exists (hashicorp/terraform-provider-aws#47598).
resource "terraform_data" "mfa_config" {
  triggers_replace = {
    user_pool_id = aws_cognito_user_pool.employees.id
    mfa          = local.mfa
  }

  provisioner "local-exec" {
    interpreter = [
      "aws", "cognito-idp", "set-user-pool-mfa-config",
      "--region", local.region,
      "--user-pool-id", aws_cognito_user_pool.employees.id,
      "--mfa-configuration", local.mfa.configuration,
      "--software-token-mfa-configuration", "Enabled=${local.mfa.totp_enabled}",
      "--web-authn-configuration",
    ]
    command = "UserVerification=${local.mfa.user_verification},FactorConfiguration=${local.mfa.passkey_factor}"
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
# AssociateSoftwareToken to set up an authenticator app from the Employees
# page). It grants nothing over
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
