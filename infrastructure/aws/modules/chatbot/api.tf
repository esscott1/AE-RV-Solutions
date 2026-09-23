# REST API rather than HTTP API: only REST APIs have usage plans (the daily
# quota), request-body validation before anything is billed, and mapping
# templates to shape Step Functions' response.
#
# CORS allows any origin. The chat has no cookies or login to protect, and
# CORS only restrains browsers: a scraper ignores it. The real volume
# controls are the usage plan and the on/off flag.

resource "aws_api_gateway_rest_api" "chat" {
  name        = var.name_prefix
  description = "A&E RV Solutions public chatbot"
  tags        = var.tags

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.chat.id
  parent_id   = aws_api_gateway_rest_api.chat.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.chat.id
  parent_id   = aws_api_gateway_resource.chat.id
  path_part   = "status"
}

# --- API Gateway's own role: start the state machine, read the flag --------

data "aws_iam_policy_document" "apigw_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw" {
  name               = "${var.name_prefix}-apigw"
  assume_role_policy = data.aws_iam_policy_document.apigw_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "apigw" {
  statement {
    sid       = "RunChatFlow"
    actions   = ["states:StartSyncExecution"]
    resources = [aws_sfn_state_machine.flow.arn]
  }

  statement {
    sid       = "ReadFlag"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.enabled.arn]
  }
}

resource "aws_iam_role_policy" "apigw" {
  name   = "chatbot-api"
  role   = aws_iam_role.apigw.id
  policy = data.aws_iam_policy_document.apigw.json
}

# --- POST /chat ---------------------------------------------------------------

# Rejects malformed or oversized conversations with a 400 before Step
# Functions or Bedrock are ever called. The state machine re-checks the same
# rules.
resource "aws_api_gateway_model" "chat_request" {
  rest_api_id  = aws_api_gateway_rest_api.chat.id
  name         = "ChatRequest"
  content_type = "application/json"
  schema = jsonencode({
    "$schema"            = "http://json-schema.org/draft-04/schema#"
    type                 = "object"
    additionalProperties = false
    required             = ["messages"]
    properties = {
      messages = {
        type     = "array"
        minItems = 1
        maxItems = var.max_messages
        items = {
          oneOf = [
            {
              type                 = "object"
              additionalProperties = false
              required             = ["role", "content"]
              properties = {
                role    = { type = "string", enum = ["user"] }
                content = { type = "string", minLength = 1, maxLength = var.max_user_message_chars }
              }
            },
            {
              type                 = "object"
              additionalProperties = false
              required             = ["role", "content"]
              properties = {
                role    = { type = "string", enum = ["assistant"] }
                content = { type = "string", minLength = 1, maxLength = var.max_assistant_message_chars }
              }
            },
          ]
        }
      }
    }
  })
}

resource "aws_api_gateway_request_validator" "body" {
  rest_api_id           = aws_api_gateway_rest_api.chat.id
  name                  = "body"
  validate_request_body = true
}

resource "aws_api_gateway_method" "chat_post" {
  rest_api_id          = aws_api_gateway_rest_api.chat.id
  resource_id          = aws_api_gateway_resource.chat.id
  http_method          = "POST"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.body.id
  request_models       = { "application/json" = aws_api_gateway_model.chat_request.name }
}

resource "aws_api_gateway_integration" "chat_post" {
  rest_api_id             = aws_api_gateway_rest_api.chat.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = aws_api_gateway_method.chat_post.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${local.region}:states:action/StartSyncExecution"
  credentials             = aws_iam_role.apigw.arn
  passthrough_behavior    = "NEVER"

  # Only `messages` is forwarded. escapeJavaScript also escapes single
  # quotes as \', which isn't valid JSON, so those are undone.
  request_templates = {
    "application/json" = <<-EOT
      #set($messages = $util.escapeJavaScript($input.json('$.messages')).replaceAll("\\'", "'"))
      {
        "stateMachineArn": "${aws_sfn_state_machine.flow.arn}",
        "input": "{\"messages\": $messages}"
      }
    EOT
  }
}

resource "aws_api_gateway_method_response" "chat_post_200" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.chat.id
  http_method         = aws_api_gateway_method.chat_post.http_method
  status_code         = "200"
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = true }
}

resource "aws_api_gateway_method_response" "chat_post_502" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.chat.id
  http_method         = aws_api_gateway_method.chat_post.http_method
  status_code         = "502"
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = true }
}

# StartSyncExecution answers 200 even when the workflow fails, so the
# template checks the execution status itself. Its `output` is already the
# JSON reply, so it's returned as-is.
resource "aws_api_gateway_integration_response" "chat_post_200" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.chat.id
  http_method         = aws_api_gateway_method.chat_post.http_method
  status_code         = aws_api_gateway_method_response.chat_post_200.status_code
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = "'*'" }

  response_templates = {
    "application/json" = <<-EOT
      #if($input.path('$.status') == "SUCCEEDED")
      $input.path('$.output')
      #else
      #set($context.responseOverride.status = 502)
      {"route": "unavailable", "reply": "${local.replies.unavailable}"}
      #end
    EOT
  }

  depends_on = [aws_api_gateway_integration.chat_post]
}

resource "aws_api_gateway_integration_response" "chat_post_error" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.chat.id
  http_method         = aws_api_gateway_method.chat_post.http_method
  status_code         = aws_api_gateway_method_response.chat_post_502.status_code
  selection_pattern   = "4\\d{2}|5\\d{2}"
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = "'*'" }
  response_templates = {
    "application/json" = jsonencode({ route = "unavailable", reply = local.replies.unavailable })
  }

  depends_on = [aws_api_gateway_integration.chat_post]
}

# --- GET /chat/status: is the chatbot switched on? ------------------------

# No API key, so page views don't use up the chat quota. Reads the same flag
# the state machine enforces; any error reports "off".
resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.chat.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_get" {
  rest_api_id             = aws_api_gateway_rest_api.chat.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_get.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${local.region}:ssm:action/GetParameter"
  credentials             = aws_iam_role.apigw.arn
  passthrough_behavior    = "NEVER"
  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-amz-json-1.1'"
  }
  request_templates = {
    "application/json" = jsonencode({ Name = local.flag_name })
  }
}

resource "aws_api_gateway_method_response" "status_get_200" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.status.id
  http_method         = aws_api_gateway_method.status_get.http_method
  status_code         = "200"
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = true }
}

# A second 200 response for errors used to be declared here. Both pointed
# at the same AWS object, so destroying it would also delete the response
# above. This drops it from state without touching AWS. It can be deleted
# once applied.
removed {
  from = aws_api_gateway_integration_response.status_get_error

  lifecycle {
    destroy = false
  }
}

# One response for every outcome: API Gateway keeps a single integration
# response per status code, and this default (no selection pattern) also
# receives SSM errors. An error body has no Parameter.Value, so it reports
# "off".
resource "aws_api_gateway_integration_response" "status_get_200" {
  rest_api_id         = aws_api_gateway_rest_api.chat.id
  resource_id         = aws_api_gateway_resource.status.id
  http_method         = aws_api_gateway_method.status_get.http_method
  status_code         = aws_api_gateway_method_response.status_get_200.status_code
  response_parameters = { "method.response.header.Access-Control-Allow-Origin" = "'*'" }
  response_templates = {
    "application/json" = <<-EOT
      {"enabled": #if($input.path('$.Parameter.Value') == "true")true#{else}false#end}
    EOT
  }

  depends_on = [aws_api_gateway_integration.status_get]
}

# --- CORS preflight (OPTIONS) for both resources -----------------------------

locals {
  cors_resources = {
    chat   = { id = aws_api_gateway_resource.chat.id, methods = "'POST,OPTIONS'" }
    status = { id = aws_api_gateway_resource.status.id, methods = "'GET,OPTIONS'" }
  }
}

resource "aws_api_gateway_method" "options" {
  for_each      = local.cors_resources
  rest_api_id   = aws_api_gateway_rest_api.chat.id
  resource_id   = each.value.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options" {
  for_each          = local.cors_resources
  rest_api_id       = aws_api_gateway_rest_api.chat.id
  resource_id       = each.value.id
  http_method       = aws_api_gateway_method.options[each.key].http_method
  type              = "MOCK"
  request_templates = { "application/json" = jsonencode({ statusCode = 200 }) }
}

resource "aws_api_gateway_method_response" "options_200" {
  for_each    = local.cors_resources
  rest_api_id = aws_api_gateway_rest_api.chat.id
  resource_id = each.value.id
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

resource "aws_api_gateway_integration_response" "options_200" {
  for_each    = local.cors_resources
  rest_api_id = aws_api_gateway_rest_api.chat.id
  resource_id = each.value.id
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = aws_api_gateway_method_response.options_200[each.key].status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = each.value.methods
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,x-api-key'"
    "method.response.header.Access-Control-Max-Age"       = "'600'"
  }

  depends_on = [aws_api_gateway_integration.options]
}

# --- Errors API Gateway raises itself: readable by the widget, same shape as
# a reply ------------------------------------------------------------------

locals {
  gateway_errors = {
    QUOTA_EXCEEDED   = { status = "429", template = jsonencode({ route = "busy", reply = "We're getting a lot of questions right now. Please try again tomorrow or contact A&E RV Solutions directly." }) }
    THROTTLED        = { status = "429", template = jsonencode({ route = "busy", reply = "We're getting a lot of questions right now. Please wait a moment and try again." }) }
    BAD_REQUEST_BODY = { status = "400", template = jsonencode({ route = "invalid", reply = local.replies.invalid }) }
    DEFAULT_5XX      = { status = null, template = jsonencode({ route = "unavailable", reply = local.replies.unavailable }) }
    # AWS's own default body, stated explicitly (an empty template gets
    # filled in by AWS, a permanent plan diff). Only the CORS header is added.
    DEFAULT_4XX = { status = null, template = "{\"message\":$context.error.messageString}" }
  }
}

resource "aws_api_gateway_gateway_response" "errors" {
  for_each      = local.gateway_errors
  rest_api_id   = aws_api_gateway_rest_api.chat.id
  response_type = each.key
  status_code   = each.value.status

  response_parameters = { "gatewayresponse.header.Access-Control-Allow-Origin" = "'*'" }
  response_templates  = { "application/json" = each.value.template }
}

# --- Deployment, stage, quota -------------------------------------------------

resource "aws_api_gateway_deployment" "chat" {
  rest_api_id = aws_api_gateway_rest_api.chat.id

  # TEMPORARY, step 1 of 2: pinned to the live deployment's trigger. Forgetting
  # status_get_error (the removed block above) and replacing this
  # create_before_destroy deployment in the same apply forms a dependency
  # cycle, so this apply doesn't redeploy. Nothing in it changes the live API.
  #
  # Step 2 (the next PR) switches to a config-only hash and deletes the
  # removed block:
  #   sha1(jsonencode([filesha1("${path.module}/api.tf"), local.replies,
  #     local.flag_name, aws_sfn_state_machine.flow.arn, var.max_messages,
  #     var.max_user_message_chars, var.max_assistant_message_chars]))
  # Hashing whole resources, as the first version did, redeployed on every
  # plan because AWS fills in fields such as cache_key_parameters after
  # creation.
  triggers = {
    redeployment = "bbd20a95ba0ccee8af7c83600217c25afbd813cf"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "v1" {
  rest_api_id   = aws_api_gateway_rest_api.chat.id
  deployment_id = aws_api_gateway_deployment.chat.id
  stage_name    = "v1"
  tags          = var.tags
}

# Per-method metrics on POST /chat, which the usage-spike alarm watches (the
# API-wide count would also include status checks). Status checks get their
# own throttle, since they carry no API key.
resource "aws_api_gateway_method_settings" "chat_post" {
  rest_api_id = aws_api_gateway_rest_api.chat.id
  stage_name  = aws_api_gateway_stage.v1.stage_name
  method_path = "chat/POST"

  settings {
    metrics_enabled = true
  }
}

resource "aws_api_gateway_method_settings" "status_get" {
  rest_api_id = aws_api_gateway_rest_api.chat.id
  stage_name  = aws_api_gateway_stage.v1.stage_name
  method_path = "chat/status/GET"

  settings {
    throttling_rate_limit  = 2
    throttling_burst_limit = 5
  }
}

# The key ships inside the public site. It isn't a secret: it's what ties
# requests to the usage plan, whose throttle and daily quota cap total cost.
resource "aws_api_gateway_api_key" "site" {
  name        = "${var.name_prefix}-site"
  description = "Public key embedded in aervsolutions.com; exists only to apply the usage plan."
  tags        = var.tags
}

resource "aws_api_gateway_usage_plan" "site" {
  name        = "${var.name_prefix}-site"
  description = "Caps total chatbot volume (and so Bedrock cost) across all visitors."
  tags        = var.tags

  api_stages {
    api_id = aws_api_gateway_rest_api.chat.id
    stage  = aws_api_gateway_stage.v1.stage_name
  }

  quota_settings {
    limit  = var.daily_quota
    period = "DAY"
  }

  throttle_settings {
    rate_limit  = var.throttle_rate_limit
    burst_limit = var.throttle_burst_limit
  }
}

resource "aws_api_gateway_usage_plan_key" "site" {
  key_id        = aws_api_gateway_api_key.site.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.site.id
}

# --- Usage-spike alert to the owner --------------------------------------

resource "aws_cloudwatch_metric_alarm" "usage_spike" {
  alarm_name        = "${var.name_prefix}-usage-spike"
  alarm_description = "More than ${var.spike_alarm_threshold} chatbot requests in an hour. If this isn't real customer traffic, switch the chatbot off with the 'Chatbot on/off' GitHub workflow."
  namespace         = "AWS/ApiGateway"
  metric_name       = "Count"
  dimensions = {
    ApiName  = aws_api_gateway_rest_api.chat.name
    Stage    = aws_api_gateway_stage.v1.stage_name
    Resource = "/chat"
    Method   = "POST"
  }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.spike_alarm_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.owner_alerts_topic_arn]
  tags                = var.tags
}
