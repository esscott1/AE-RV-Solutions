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
profile        = "OTS-Prod-Deploy"
