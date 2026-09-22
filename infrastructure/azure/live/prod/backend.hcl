# Partial backend config for `terraform init -backend-config=backend.hcl`.
# Fill these in from `infrastructure/azure/bootstrap`'s outputs after
# running `terraform apply` there once:
#   terraform -chdir=../../bootstrap output -raw resource_group_name
#   terraform -chdir=../../bootstrap output -raw storage_account_name
#   terraform -chdir=../../bootstrap output -raw container_name

resource_group_name  = "REPLACE_WITH_resource_group_name_OUTPUT"
storage_account_name = "REPLACE_WITH_storage_account_name_OUTPUT"
container_name        = "REPLACE_WITH_container_name_OUTPUT"
key                    = "live/prod/terraform.tfstate"
