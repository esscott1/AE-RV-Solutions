variable "region" {
  description = "AWS region for this environment's resources."
  type        = string
  default     = "us-west-2"
}

variable "repository_url" {
  description = "HTTPS URL of the GitHub repository."
  type        = string
  default     = "https://github.com/esscott1/AE-RV-Solutions"
}
