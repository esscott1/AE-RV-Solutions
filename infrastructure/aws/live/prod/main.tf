module "amplify" {
  source = "../../modules/amplify"

  app_name            = "ae-rv-solutions-prod"
  repository_url      = var.repository_url
  branch_name         = "main"
  app_root            = "site"
  github_access_token = var.github_access_token
}
