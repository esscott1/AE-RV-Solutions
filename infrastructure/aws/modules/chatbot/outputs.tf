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
