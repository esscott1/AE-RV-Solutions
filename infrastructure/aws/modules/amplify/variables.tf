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
