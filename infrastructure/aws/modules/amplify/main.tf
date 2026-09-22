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
}

resource "aws_amplify_webhook" "deploy" {
  app_id      = aws_amplify_app.this.id
  branch_name = aws_amplify_branch.this.branch_name
  description = "Triggered by .github/workflows/deploy-site.yml on pushes to ${var.branch_name} that touch site/."
}
