terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile

  # Every resource bootstrap creates is tagged. IAM inline policies, the SNS
  # subscription, and the S3 bucket's sub-resources can't be; the provider
  # skips those.
  default_tags {
    tags = {
      Customer = "AERVSolutions"
    }
  }
}
