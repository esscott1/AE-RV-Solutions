resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_static_web_app" "this" {
  # No repository_url/repository_branch/repository_token: deployment is
  # driven entirely by GitHub Actions using this resource's `api_key`
  # (see .github/workflows/deploy-azure.yml), not Azure's own repo
  # connection. That avoids Azure auto-generating its own workflow file
  # and needing a stored GitHub PAT.
  name                = var.app_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku_tier            = "Free"
  sku_size            = "Free"
}
