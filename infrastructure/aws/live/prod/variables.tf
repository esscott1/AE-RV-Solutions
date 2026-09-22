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

variable "domain_name" {
  description = "Custom domain served by the Amplify app. Needs a default: terraform-aws.yml wires no TF_VAR_domain_name and there is no terraform.tfvars, so a required variable here would break the CI apply. Lowercase is functional, not cosmetic - Route 53 stores the zone as aervsolutions.com. and the Amplify association's domainName is lowercase regardless of input casing."
  type        = string
  default     = "aervsolutions.com"
}
