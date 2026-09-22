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
  # No access_token/oauth_token: this assumes the AWS Amplify GitHub App has
  # already been authorized once for this GitHub account (a manual, one-time
  # step in the Amplify console — see infrastructure/README.md) and that a
  # newly Terraform-created app can reuse that connection. If `terraform
  # apply` fails at repository/webhook setup, fall back to a personal
  # access token via var access_token/oauth_token instead.
  name       = var.app_name
  repository = var.repository_url
  platform   = "WEB"

  build_spec               = local.build_spec
  environment_variables    = local.environment_variables
  enable_branch_auto_build = false
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
  description = "Triggered by .github/workflows/deploy.yml on pushes to ${var.branch_name} that touch site/."
}
