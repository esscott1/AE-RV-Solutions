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
