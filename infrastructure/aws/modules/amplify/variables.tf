variable "app_name" {
  description = "Name of the Amplify app."
  type        = string
}

variable "repository_url" {
  description = "HTTPS URL of the GitHub repository, e.g. https://github.com/esscott1/AE-RV-Solutions."
  type        = string
}

variable "branch_name" {
  description = "Git branch to deploy from."
  type        = string
  default     = "main"
}

variable "app_root" {
  description = "Directory within the repository that the Astro project lives in (monorepo app root)."
  type        = string
  default     = "site"
}

variable "environment_variables" {
  description = "Additional Amplify app-level environment variables, merged with the required AMPLIFY_MONOREPO_APP_ROOT entry."
  type        = map(string)
  default     = {}
}

variable "build_spec" {
  description = "Amplify build spec (amplify.yml contents). Defaults to a monorepo static build rooted at var.app_root."
  type        = string
  default     = null
}

variable "github_access_token" {
  description = "GitHub personal access token (classic; repo + admin:repo_hook scopes) Amplify uses to create the app's repository connection and webhook. Required: the Amplify CreateApp API always needs an explicit token, even when the AWS Amplify GitHub App has already been authorized in the console for this account - that authorization only carries over automatically within the console's own browser session, not for API/Terraform-driven app creation."
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Custom domain to associate with the app, e.g. aervsolutions.com. Empty string disables the association entirely. Must be lowercase: Route 53 and the Amplify API both normalise to lowercase, so mixed case produces a permanent diff."
  type        = string
  default     = ""
}
