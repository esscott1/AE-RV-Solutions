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

output "github_actions_role_arn" {
  description = "IAM role terraform-aws.yml assumes via OIDC. Set as the AWS_TERRAFORM_ROLE_ARN repository variable (Settings -> Secrets and variables -> Actions -> Variables)."
  value       = aws_iam_role.github_actions_terraform.arn
}

output "github_actions_plan_role_arn" {
  description = "Read-only IAM role terraform-aws-plan.yml assumes via OIDC on pull requests. Set as the AWS_TERRAFORM_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions_terraform_plan.arn
}

output "github_actions_chatbot_toggle_role_arn" {
  description = "IAM role chatbot-toggle.yml assumes via OIDC to flip the chatbot on or off. Set as the AWS_CHATBOT_TOGGLE_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions_chatbot_toggle.arn
}

output "owner_alerts_topic_name" {
  description = "SNS topic for owner alerts. modules/chatbot looks it up by this name for its usage-spike alarm."
  value       = aws_sns_topic.owner_alerts.name
}
