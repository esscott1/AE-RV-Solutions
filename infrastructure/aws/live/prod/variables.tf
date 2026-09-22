variable "region" {
  description = "AWS region for this environment's resources."
  type        = string
  default     = "us-west-2"
}

variable "profile" {
  description = "Named AWS CLI profile to authenticate with (see `aws configure list-profiles`)."
  type        = string
  default     = "OTS-Prod-Deploy"
}

variable "repository_url" {
  description = "HTTPS URL of the GitHub repository."
  type        = string
  default     = "https://github.com/esscott1/AE-RV-Solutions"
}

variable "github_access_token" {
  description = "GitHub personal access token (classic; repo + admin:repo_hook scopes) Amplify uses to create the app's repository connection and webhook. Pass via -var or TF_VAR_github_access_token - never commit a real value here."
  type        = string
  sensitive   = true
}
