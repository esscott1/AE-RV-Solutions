# Partial backend config for `terraform init -backend-config=backend.hcl`.
# Fill these in from `infrastructure/aws/bootstrap`'s outputs after running
# `terraform apply` there once:
#   terraform -chdir=../../bootstrap output -raw state_bucket_name
#   terraform -chdir=../../bootstrap output -raw lock_table_name
#   terraform -chdir=../../bootstrap output -raw region

bucket         = "ae-rv-solutions-tfstate-998976076628"
dynamodb_table = "ae-rv-solutions-tfstate-lock"
region         = "us-west-2"
key            = "live/prod/terraform.tfstate"
encrypt        = true
# No `profile` here on purpose: this file is shared between local runs and
# CI. Backend blocks can't reference Terraform variables (unlike the
# provider block's conditional `var.profile`), so a hardcoded profile here
# would break CI the same way it broke the provider block. For local runs,
# set AWS_PROFILE=OTS-Prod-Deploy in your shell before running terraform -
# both the backend and the provider fall back to it automatically. CI
# needs nothing extra: the OIDC-assumed role's credentials are already in
# the environment.
