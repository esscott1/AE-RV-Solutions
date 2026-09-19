variable "region" {
  description = "AWS region for the state backend resources."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Short project name used to namespace the state bucket and lock table."
  type        = string
  default     = "ae-rv-solutions"
}
