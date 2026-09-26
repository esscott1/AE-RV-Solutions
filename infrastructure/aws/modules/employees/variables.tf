variable "name_prefix" {
  description = "Prefix for every resource name. The CI roles' employee permissions (bootstrap/employees.tf) are scoped to it, so the two must match."
  type        = string
  default     = "ae-rv-employees"
}

variable "domain_prefix" {
  description = "Cognito prefix domain for the sign-in pages: <prefix>.auth.<region>.amazoncognito.com. Passkeys are tied to this domain, so changing it means every employee registers theirs again."
  type        = string
  default     = "ae-rv-employees"
}

variable "site_origins" {
  description = "Origins the employee pages are served from. Each gets a sign-in callback and sign-out URL at /employees/, and is allowed by the API's CORS."
  type        = list(string)
  default = [
    "https://aervsolutions.com",
    "https://www.aervsolutions.com",
    "http://localhost:4321",
  ]
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second the employee API allows, across all callers."
  type        = number
  default     = 2
}

variable "throttle_burst_limit" {
  description = "Request burst the employee API allows, across all callers."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "transcripts_bucket" {
  description = "The chatbot's transcripts bucket (modules/chatbot). The admin API reads it."
  type        = string
}

variable "usage_plan_id" {
  description = "The chat API's usage plan (modules/chatbot). The admin API reads its daily usage."
  type        = string
}

variable "api_key_id" {
  description = "The chat API's site key (modules/chatbot), whose daily usage the admin API reports."
  type        = string
}

variable "price_per_mtok_input" {
  description = "Estimated Bedrock price per million input tokens, for the admin page's cost estimates (Claude Haiku 4.5 through the us inference profile)."
  type        = number
  default     = 1.10
}

variable "price_per_mtok_output" {
  description = "Estimated Bedrock price per million output tokens, for the admin page's cost estimates."
  type        = number
  default     = 5.50
}

variable "kb_docs_bucket" {
  description = "The knowledge base's documents bucket (modules/chatbot). The knowledge API keeps pending/, rejected/ and approved/ entries there."
  type        = string
}

variable "knowledge_base_id" {
  description = "Eddie's Bedrock knowledge base (modules/chatbot)."
  type        = string
}

variable "kb_data_source_id" {
  description = "The knowledge base's S3 data source (modules/chatbot), re-indexed after approvals and removals."
  type        = string
}

variable "model_id" {
  description = "The Bedrock inference profile ARN Herman calls (modules/chatbot: the same Claude Haiku 4.5 profile as Eddie)."
  type        = string
}

variable "model_invoke_arns" {
  description = "Everything IAM must allow for invoking model_id: the inference profile and its foundation model in every region the profile routes to (modules/chatbot)."
  type        = list(string)
}

variable "feature_flags" {
  description = "Feature switches from other modules that the admin Feature Mgr page can turn on and off: name -> SSM parameter holding \"true\" or \"false\". Herman's switch is added by this module. Each name also needs an entry in lambda/features.py FEATURES."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for name, parameter in var.feature_flags : can(regex("^[a-z][a-z0-9-]*$", name)) && startswith(parameter, "/")])
    error_message = "Names are lowercase words (a-z, 0-9, -); parameters are full names starting with /."
  }
}

variable "flag_workflow_role_name" {
  description = "The role the 'Chatbot on/off' GitHub workflow uses (bootstrap/chatbot.tf), so the Feature Mgr page can label its changes in a switch's history."
  type        = string
  default     = "github-actions-chatbot-toggle"
}

variable "terraform_role_name" {
  description = "The role Terraform's CI applies run as (bootstrap/main.tf), so the Feature Mgr page labels the changes it makes, such as creating a switch, as \"Terraform\"."
  type        = string
  default     = "github-actions-terraform"
}

variable "herman_flag_name" {
  description = "SSM parameter for Herman's on/off switch. Under /ae-rv/chatbot/, the path the CI roles can already manage (bootstrap/chatbot.tf), so no bootstrap change is needed."
  type        = string
  default     = "/ae-rv/chatbot/herman/enabled"
}
