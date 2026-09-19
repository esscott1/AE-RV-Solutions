variable "app_name" {
  description = "Name of the Static Web App."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group to create for this app's resources."
  type        = string
}

variable "location" {
  description = "Azure region. Static Web Apps is only available in a subset of regions (West US 2, Central US, East US 2, West Europe, East Asia)."
  type        = string
  default     = "West US 2"
}
