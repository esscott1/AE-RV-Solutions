data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  inference_profile_arn = "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/${var.inference_profile_id}"
  foundation_model_arns = [
    for r in var.inference_profile_regions : "arn:aws:bedrock:${r}::foundation-model/${var.foundation_model_id}"
  ]

  flag_name = "/ae-rv/chatbot/enabled"

  # Built rather than looked up: a data "aws_sns_topic" lookup needs
  # sns:ListTopics across the whole account.
  owner_alerts_topic_arn = "arn:aws:sns:${local.region}:${local.account_id}:${var.owner_alerts_topic_name}"

  # Fixed replies. Every route except `answer` returns one of these verbatim:
  # the model never writes a safety, emergency, decline, or offline message.
  replies = {
    offline         = "Chat is offline right now. Please contact A&E RV Solutions directly."
    invalid         = "Sorry, I couldn't process that message. Please keep messages short and try again."
    unavailable     = "Sorry, I can't answer right now. Please try again later or contact A&E RV Solutions directly."
    safety_referral = "This involves work that can be dangerous: live electrical circuits, batteries, or shore power, generator, or inverter connections. For your safety, please don't attempt it yourself. Contact A&E RV Solutions to have a qualified technician take a look."
    emergency       = "This could be an emergency. If you smell propane, see smoke or fire, or a CO or propane alarm is sounding: get everyone out of the RV now, don't operate switches or open flames, and call 911 from a safe distance. Once everyone is safe, contact A&E RV Solutions for follow-up service."
    decline         = "I can only help with questions about A&E RV Solutions and general RV solar, inverter, and troubleshooting topics. I can't share how I'm set up or provide information in bulk."
  }
}

# --- On/off feature flag ---------------------------------------------------

# The chatbot's kill switch, read on every request by both the state machine
# and GET /chat/status. It's flipped outside Terraform (chatbot-toggle.yml or
# the console), so Terraform only sets the initial value: without
# ignore_changes, every apply would silently reset it.
resource "aws_ssm_parameter" "enabled" {
  name        = local.flag_name
  description = "Chatbot on/off switch: \"true\" or \"false\". Flip it with the 'Chatbot on/off' GitHub workflow."
  type        = "String"
  value       = "false"
  tags        = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

# --- State machine -----------------------------------------------------------

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-flow"
  retention_in_days = 14
  tags              = var.tags
}

data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "sfn" {
  # Invoking through an inference profile needs the profile and the model in
  # every region it routes to.
  statement {
    sid       = "InvokeHaiku"
    actions   = ["bedrock:InvokeModel"]
    resources = concat([local.inference_profile_arn], local.foundation_model_arns)
  }

  statement {
    sid       = "ReadFlag"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.enabled.arn]
  }

  # Step Functions log delivery; AWS only authorizes these on "*".
  statement {
    sid = "LogDelivery"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "chatbot-flow"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

locals {
  bedrock_retry = [{
    ErrorEquals     = ["Bedrock.ThrottlingException", "Bedrock.ServiceUnavailableException", "Bedrock.InternalServerException"]
    IntervalSeconds = 1
    MaxAttempts     = 2
    BackoffRate     = 2
  }]

  # Customer messages are handed to the classifier as quoted data, not as
  # chat turns, so a message can't pose as instructions to it.
  transcript = "'<conversation>\\n' & $join($messages.((role = 'user' ? 'Customer: ' : 'Assistant: ') & content), '\\n\\n') & '\\n</conversation>'"

  valid_conversation = join(" and ", [
    "$type($messages) = 'array'",
    "$count($messages) >= 1",
    "$count($messages) <= ${var.max_messages}",
    "$messages[0].role = 'user'",
    "$messages[-1].role = 'user'",
    "$count($messages[$not(role in ['user', 'assistant'])]) = 0",
    "$count($messages[$type(content) != 'string']) = 0",
    "$count($messages[$length(content) = 0]) = 0",
    "$count($messages[role = 'user' and $length(content) > ${var.max_user_message_chars}]) = 0",
    "$count($messages[role = 'assistant' and $length(content) > ${var.max_assistant_message_chars}]) = 0",
  ])

  fixed_reply_states = {
    for route, text in local.replies : "Reply_${route}" => {
      Type   = "Pass"
      Output = { route = route, reply = text }
      End    = true
    }
  }

  definition = {
    Comment       = "A&E RV Solutions public chatbot: on/off flag, then the safety gate (classifier), then an answer or a fixed reply."
    QueryLanguage = "JSONata"
    StartAt       = "CheckFlag"
    States = merge(local.fixed_reply_states, {
      # A missing or unreadable flag counts as off.
      CheckFlag = {
        Type      = "Task"
        Resource  = "arn:aws:states:::aws-sdk:ssm:getParameter"
        Arguments = { Name = local.flag_name }
        Assign    = { messages = "{% $states.input.messages %}" }
        Output    = { enabled = "{% $states.result.Parameter.Value = 'true' %}" }
        Catch     = [{ ErrorEquals = ["States.ALL"], Next = "Reply_offline" }]
        Next      = "IsEnabled"
      }

      IsEnabled = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $states.input.enabled = true %}", Next = "Validate" }]
        Default = "Reply_offline"
      }

      # Repeats the API's request schema, in case the state machine is ever
      # invoked some other way.
      Validate = {
        Type    = "Choice"
        Choices = [{ Condition = "{% ${local.valid_conversation} %}", Next = "Classify" }]
        Default = "Reply_invalid"
      }

      # The safety gate. A forced, schema-strict tool call makes the route
      # machine-readable. Any failure fails closed to the safety referral.
      Classify = {
        Type     = "Task"
        Resource = "arn:aws:states:::bedrock:invokeModel"
        Arguments = {
          ModelId     = local.inference_profile_arn
          ContentType = "application/json"
          Accept      = "application/json"
          Body = {
            anthropic_version = "bedrock-2023-05-31"
            max_tokens        = 200
            temperature       = 0
            system            = file("${path.module}/prompts/classifier.md")
            tools = [{
              name        = "route_message"
              description = "Record how the latest customer message must be handled."
              strict      = true
              input_schema = {
                type                 = "object"
                additionalProperties = false
                required             = ["route", "reason"]
                properties = {
                  route  = { type = "string", enum = ["answer", "safety_referral", "emergency", "decline"] }
                  reason = { type = "string", description = "One short sentence explaining the choice." }
                }
              }
            }]
            tool_choice = { type = "tool", name = "route_message" }
            messages = [{
              role    = "user"
              content = "{% ${local.transcript} %}"
            }]
          }
        }
        Output = { route = "{% ($states.result.Body.content[type = 'tool_use'].input.route)[0] %}" }
        Retry  = local.bedrock_retry
        Catch  = [{ ErrorEquals = ["States.ALL"], Next = "Reply_safety_referral" }]
        Next   = "Route"
      }

      # Anything but an exact match on a known route fails closed.
      Route = {
        Type = "Choice"
        Choices = [
          { Condition = "{% $states.input.route = 'emergency' %}", Next = "Reply_emergency" },
          { Condition = "{% $states.input.route = 'decline' %}", Next = "Reply_decline" },
          { Condition = "{% $states.input.route = 'answer' %}", Next = "Answer" },
        ]
        Default = "Reply_safety_referral"
      }

      Answer = {
        Type     = "Task"
        Resource = "arn:aws:states:::bedrock:invokeModel"
        Arguments = {
          ModelId     = local.inference_profile_arn
          ContentType = "application/json"
          Accept      = "application/json"
          Body = {
            anthropic_version = "bedrock-2023-05-31"
            max_tokens        = var.answer_max_tokens
            system            = file("${path.module}/prompts/assistant.md")
            messages          = "{% $messages %}"
          }
        }
        # A truncated or empty answer is replaced rather than shown half-done.
        Output = "{% ($text := $join($states.result.Body.content[type = 'text'].text, ''); $ok := $states.result.Body.stop_reason = 'end_turn' and $exists($text) and $length($text) > 0; {'route': 'answer', 'reply': $ok ? $text : \"${local.replies.unavailable}\"}) %}"
        Retry  = local.bedrock_retry
        Catch  = [{ ErrorEquals = ["States.ALL"], Next = "Reply_unavailable" }]
        End    = true
      }
    })
  }
}

resource "aws_sfn_state_machine" "flow" {
  name       = "${var.name_prefix}-flow"
  type       = "EXPRESS"
  role_arn   = aws_iam_role.sfn.arn
  definition = jsonencode(local.definition)
  tags       = var.tags

  # Errors only, and never execution data: that would log every customer
  # message.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }
}
