# Partial backend config for `terraform init -backend-config=backend.hcl`.
# Values come from `infrastructure/aws/bootstrap`'s outputs:
#   terraform -chdir=../../bootstrap output -raw state_bucket_name
#   terraform -chdir=../../bootstrap output -raw region

bucket  = "ae-rv-solutions-tfstate-998976076628"
region  = "us-west-2"
key     = "live/prod/terraform.tfstate"
encrypt = true

# Native S3 state locking (Terraform >= 1.10), replacing the deprecated
# `dynamodb_table` parameter - the provider now warns that it's deprecated
# in favour of this. The lock is a .tflock object alongside the state file
# in the same bucket; the DynamoDB table bootstrap created is no longer
# used by this backend and can be removed in a later pass.
use_lockfile = true

# No `profile` here on purpose: this file is shared between local runs and
# CI. Backend blocks can't reference Terraform variables (unlike the
# provider block's conditional `var.profile`), so a hardcoded profile here
# would break CI the same way it broke the provider block. For local runs,
# set AWS_PROFILE=OTS-Prod-Deploy in your shell before running terraform -
# both the backend and the provider fall back to it automatically. CI
# needs nothing extra: the OIDC-assumed role's credentials are already in
# the environment.
