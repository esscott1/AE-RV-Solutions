variable "region" {
  description = "AWS region for the state backend resources."
  type        = string
  default     = "us-west-2"
}

variable "profile" {
  description = "Named AWS CLI profile to authenticate with (see `aws configure list-profiles`)."
  type        = string
  default     = "OTS-Prod-Deploy"
}

variable "project_name" {
  description = "Short project name used to namespace the state bucket and lock table."
  type        = string
  default     = "ae-rv-solutions"
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) allowed to assume the CI Terraform role via OIDC."
  type        = string
  default     = "esscott1/AE-RV-Solutions"
}

variable "amplify_app_id" {
  description = "ID of the Amplify app live/prod manages (`terraform -chdir=../live/prod output -raw amplify_app_id`). Scopes the read-only plan role's Amplify access to this one app."
  type        = string
  default     = "du8gjlas8igsf"
}

variable "hosted_zone_id" {
  description = "ID of the Route 53 hosted zone live/prod manages, without the /hostedzone/ prefix. Scopes the read-only plan role's Route 53 access to this one zone."
  type        = string
  default     = "Z04527082WQQTNVJVH95M"
}

variable "github_environment" {
  description = "GitHub Environment name whose jobs are trusted to assume the CI Terraform role. Scoping trust to an Environment (rather than the repo-wide pull_request subject) keeps this role usable by only this one workflow, and gets GitHub's environment protection rules (e.g. required reviewers) for free."
  type        = string
  default     = "aws-infra"
}

variable "chatbot_name_prefix" {
  description = "Name prefix every chatbot resource uses (state machine, IAM roles, log groups, alarms). The CI roles' chatbot permissions are scoped to it, so it must match modules/chatbot's name_prefix."
  type        = string
  default     = "ae-rv-chatbot"
}

variable "chatbot_toggle_environment" {
  description = "GitHub Environment whose jobs may assume the chatbot toggle role (used by chatbot-toggle.yml)."
  type        = string
  default     = "chatbot-toggle"
}

variable "alert_email" {
  description = "Email address for owner alerts (chatbot usage spikes and the monthly budget). No default, and never committed: set it in bootstrap/terraform.tfvars, which is gitignored (see terraform.tfvars.example)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget. Alerts at 50/80/100% of it go to alert_email."
  type        = number
  default     = 20
}
