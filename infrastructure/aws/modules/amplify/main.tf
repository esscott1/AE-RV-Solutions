locals {
  default_build_spec = <<-EOT
    version: 1
    applications:
      - appRoot: ${var.app_root}
        frontend:
          phases:
            preBuild:
              commands:
                - npm ci
            build:
              commands:
                - npm run build
          artifacts:
            baseDirectory: dist
            files:
              - '**/*'
          cache:
            paths:
              - node_modules/**/*
  EOT

  build_spec = coalesce(var.build_spec, local.default_build_spec)

  environment_variables = merge(
    { AMPLIFY_MONOREPO_APP_ROOT = var.app_root },
    var.environment_variables,
  )
}

resource "aws_amplify_app" "this" {
  # access_token is required: confirmed by a real CreateApp failure
  # ("You should at least provide one valid token") that the Amplify GitHub
  # App console authorization (infrastructure/README.md) does NOT carry
  # over to API/Terraform-driven app creation - that reuse only happens
  # within the console's own browser session. A token is always needed
  # here regardless of prior console authorization.
  name         = var.app_name
  repository   = var.repository_url
  access_token = var.github_access_token
  platform     = "WEB"

  build_spec               = local.build_spec
  environment_variables    = local.environment_variables
  enable_branch_auto_build = false

  lifecycle {
    # AWS never returns the token back, so every plan would otherwise show
    # a spurious in-place update of access_token. Rotating the token means
    # updating the secret and removing this ignore for one apply.
    ignore_changes = [access_token]

    # prevent_destroy (here, on the branch, and on the domain association)
    # makes any plan that would destroy or replace the live site fail on the
    # PR instead of applying on merge. To tear down deliberately, remove it
    # in its own PR first.
    prevent_destroy = true
  }
}

resource "aws_amplify_branch" "this" {
  app_id      = aws_amplify_app.this.id
  branch_name = var.branch_name
  stage       = "PRODUCTION"

  # Amplify's own push trigger is disabled entirely: deploys are driven by
  # the webhook below, gated through a GitHub Actions workflow that skips
  # infrastructure-only changes. See infrastructure/README.md.
  enable_auto_build = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_amplify_webhook" "deploy" {
  app_id      = aws_amplify_app.this.id
  branch_name = aws_amplify_branch.this.branch_name
  description = "Triggered by .github/workflows/deploy-site.yml on pushes to ${var.branch_name} that touch site/."
}

# Imported, not created - the association already exists in AWS and is
# AVAILABLE. Only app_id and domain_name are ForceNew on this resource, and
# both match live exactly, so no field below can trigger a replacement
# (which would drop the live domain and re-issue the certificate).
resource "aws_amplify_domain_association" "this" {
  count = var.domain_name != "" ? 1 : 0

  app_id      = aws_amplify_app.this.id
  domain_name = var.domain_name

  # Apex. The AWS API omits `prefix` entirely for the root subdomain, but
  # the Terraform argument is Required and explicitly permits "" - so it is
  # written rather than omitted.
  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = ""
  }

  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = "www"
  }

  enable_auto_sub_domain = false

  # Confirmed live via `aws amplify get-domain-association` (CLI 2.37.0,
  # which returns the `certificate` field that older CLIs omitted).
  certificate_settings {
    type = "AMPLIFY_MANAGED"
  }

  # Creation already waits unconditionally (5m). This second wait is a
  # hardcoded 15m with no configurable `timeouts` block, so leaving it on
  # risks red CI runs for reasons unrelated to the change being applied.
  wait_for_verification = false

  # Also covers count dropping to 0: blanking domain_name fails the plan
  # rather than silently dropping the live domain.
  lifecycle {
    prevent_destroy = true
  }
}
