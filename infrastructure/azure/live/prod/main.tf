module "static_web_app" {
  source = "../../modules/static-web-app"

  app_name            = "ae-rv-solutions-prod"
  resource_group_name = "ae-rv-solutions-prod-rg"
  location            = var.location
}
