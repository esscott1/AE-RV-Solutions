output "chat_api_url" {
  description = "Base URL of the chatbot API. The widget calls POST <url>/chat and GET <url>/chat/status."
  value       = aws_api_gateway_stage.v1.invoke_url
}

output "chat_api_key" {
  description = "The usage-plan key the site sends as x-api-key. Deliberately not sensitive: it ships in the public site bundle, and exists only to apply the daily quota and throttle."
  value       = nonsensitive(aws_api_gateway_api_key.site.value)
}

output "flag_parameter_name" {
  description = "SSM parameter holding the chatbot on/off switch (\"true\" or \"false\")."
  value       = aws_ssm_parameter.enabled.name
}

output "state_machine_arn" {
  description = "The chatbot's Step Functions state machine (on/off check, safety gate, answer)."
  value       = aws_sfn_state_machine.flow.arn
}

output "kb_docs_bucket" {
  description = "Private S3 bucket for the knowledge base's source documents. Upload here, then run the 'Chatbot knowledge base sync' workflow."
  value       = aws_s3_bucket.kb_docs.bucket
}

output "knowledge_base_id" {
  description = "Bedrock knowledge base ID."
  value       = aws_bedrockagent_knowledge_base.kb.id
}

output "kb_data_source_id" {
  description = "ID of the knowledge base's S3 data source (what a sync re-indexes)."
  value       = aws_bedrockagent_data_source.kb_docs.data_source_id
}

output "transcripts_bucket" {
  description = "Private S3 bucket holding chat transcripts (transcripts/YYYY/MM/DD/), deleted after transcript_retention_days."
  value       = aws_s3_bucket.transcripts.bucket
}

output "usage_plan_id" {
  description = "The chat API's usage plan (daily quota and throttle)."
  value       = aws_api_gateway_usage_plan.site.id
}

output "api_key_id" {
  description = "ID (not the value) of the site's chat API key."
  value       = aws_api_gateway_api_key.site.id
}

output "inference_profile_arn" {
  description = "The Bedrock inference profile the chatbot calls (Claude Haiku 4.5). Herman (modules/employees) uses it too."
  value       = local.inference_profile_arn
}

output "model_invoke_arns" {
  description = "Everything IAM must allow to invoke through the inference profile: the profile and its foundation model in every region it routes to."
  value       = concat([local.inference_profile_arn], local.foundation_model_arns)
}
