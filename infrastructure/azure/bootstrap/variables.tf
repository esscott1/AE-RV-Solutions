variable "location" {
  description = "Azure region for the state backend resources."
  type        = string
  default     = "West US 2"
}

variable "project_name" {
  description = "Short project name used to namespace the state resource group and storage account."
  type        = string
  default     = "ae-rv-solutions"
}
