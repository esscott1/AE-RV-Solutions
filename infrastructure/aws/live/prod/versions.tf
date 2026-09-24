terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Zips modules/employees' Lambda source.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region
  # Empty string (CI passes -var profile="") means "no named profile" -
  # rely on ambient credentials instead (OIDC-injected env vars in CI,
  # or the default profile locally).
  profile = var.profile != "" ? var.profile : null
}
