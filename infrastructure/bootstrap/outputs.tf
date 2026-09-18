output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state. Use as `bucket` in live/*/backend.hcl."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking. Use as `dynamodb_table` in live/*/backend.hcl."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "region" {
  description = "AWS region the state backend resources live in. Use as `region` in live/*/backend.hcl."
  value       = var.region
}
