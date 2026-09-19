data "azurerm_client_config" "current" {}

locals {
  resource_group_name = "${var.project_name}-tfstate-rg"

  # Storage account names must be globally unique, lowercase alphanumeric
  # only, 3-24 chars. Derive uniqueness from the subscription ID, mirroring
  # how the AWS bootstrap derives bucket uniqueness from the account ID.
  storage_account_name = "aervtfstate${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}"

  container_name = "tfstate"
}

resource "azurerm_resource_group" "tfstate" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
