# --- Public chatbot (modules/chatbot): CI permissions, the on/off toggle
# role, and owner alerts. ---
#
# Every managed resource is named with var.chatbot_name_prefix, so both CI
# roles are scoped to that prefix rather than to whole services. When a CI
# plan or apply hits an AccessDenied, add the exact action it names here and
# re-apply bootstrap locally. Don't widen to a wildcard.

locals {
  account_id     = data.aws_caller_identity.current.account_id
  chatbot_prefix = var.chatbot_name_prefix

  chatbot_state_machine_arn = "arn:aws:states:${var.region}:${local.account_id}:stateMachine:${local.chatbot_prefix}-*"
  chatbot_role_arn          = "arn:aws:iam::${local.account_id}:role/${local.chatbot_prefix}-*"
  chatbot_log_group_arn     = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/vendedlogs/states/${local.chatbot_prefix}-*"
  chatbot_parameter_arn     = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/ae-rv/chatbot/*"
  chatbot_flag_arn          = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/ae-rv/chatbot/enabled"
  chatbot_alarm_arn         = "arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:${local.chatbot_prefix}-*"

  # REST API resources have no account in their ARN, so API Gateway access
  # can only be scoped to these paths, not to one API.
  chatbot_apigateway_arns = [
    "arn:aws:apigateway:${var.region}::/restapis",
    "arn:aws:apigateway:${var.region}::/restapis/*",
    "arn:aws:apigateway:${var.region}::/usageplans",
    "arn:aws:apigateway:${var.region}::/usageplans/*",
    "arn:aws:apigateway:${var.region}::/apikeys",
    "arn:aws:apigateway:${var.region}::/apikeys/*",
    "arn:aws:apigateway:${var.region}::/tags/*",
  ]
}

# --- Apply role: manage the chatbot's resources. ---

data "aws_iam_policy_document" "github_actions_terraform_chatbot" {
  statement {
    sid    = "ManageChatbotStateMachine"
    effect = "Allow"
    actions = [
      "states:CreateStateMachine",
      "states:UpdateStateMachine",
      "states:DeleteStateMachine",
      "states:DescribeStateMachine",
      "states:ListStateMachineVersions",
      "states:ListTagsForResource",
      "states:TagResource",
      "states:UntagResource",
    ]
    resources = [local.chatbot_state_machine_arn]
  }

  statement {
    sid       = "ManageChatbotApi"
    effect    = "Allow"
    actions   = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
    resources = local.chatbot_apigateway_arns
  }

  statement {
    sid    = "ManageChatbotRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.chatbot_role_arn]
  }

  # PassRole only to the two services the chatbot's roles are for.
  statement {
    sid       = "PassChatbotRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.chatbot_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["states.amazonaws.com", "apigateway.amazonaws.com"]
    }
  }

  statement {
    sid    = "ManageChatbotLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      "logs:TagResource",
      "logs:TagLogGroup",
      "logs:UntagResource",
      "logs:UntagLogGroup",
    ]
    resources = [local.chatbot_log_group_arn, "${local.chatbot_log_group_arn}:*"]
  }

  statement {
    sid    = "ManageChatbotParameters"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [local.chatbot_parameter_arn]
  }

  statement {
    sid    = "ManageChatbotAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:ListTagsForResource",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = [local.chatbot_alarm_arn]
  }

  # The AWS provider validates the definition during plan and apply. AWS
  # authorizes this only on stateMachine:*, not on a named machine.
  statement {
    sid       = "ValidateStateMachineDefinition"
    effect    = "Allow"
    actions   = ["states:ValidateStateMachineDefinition"]
    resources = ["arn:aws:states:${var.region}:${local.account_id}:stateMachine:*"]
  }

  # List/describe calls that AWS only authorizes on "*".
  statement {
    sid    = "DescribeOnly"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "ssm:DescribeParameters",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_chatbot" {
  name   = "terraform-apply-chatbot"
  role   = aws_iam_role.github_actions_terraform.id
  policy = data.aws_iam_policy_document.github_actions_terraform_chatbot.json
}

# --- Plan role: the read-only counterpart. ---

data "aws_iam_policy_document" "github_actions_terraform_plan_chatbot" {
  statement {
    sid       = "ReadChatbotStateMachine"
    effect    = "Allow"
    actions   = ["states:DescribeStateMachine", "states:ListStateMachineVersions", "states:ListTagsForResource"]
    resources = [local.chatbot_state_machine_arn]
  }

  statement {
    sid       = "ReadChatbotApi"
    effect    = "Allow"
    actions   = ["apigateway:GET"]
    resources = local.chatbot_apigateway_arns
  }

  statement {
    sid       = "ReadChatbotRoles"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = [local.chatbot_role_arn]
  }

  statement {
    sid       = "ReadChatbotLogGroup"
    effect    = "Allow"
    actions   = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"]
    resources = [local.chatbot_log_group_arn, "${local.chatbot_log_group_arn}:*"]
  }

  statement {
    sid       = "ReadChatbotParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = [local.chatbot_parameter_arn]
  }

  statement {
    sid       = "ReadChatbotAlarms"
    effect    = "Allow"
    actions   = ["cloudwatch:ListTagsForResource"]
    resources = [local.chatbot_alarm_arn]
  }

  statement {
    sid       = "ValidateStateMachineDefinition"
    effect    = "Allow"
    actions   = ["states:ValidateStateMachineDefinition"]
    resources = ["arn:aws:states:${var.region}:${local.account_id}:stateMachine:*"]
  }

  statement {
    sid    = "DescribeOnly"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "ssm:DescribeParameters",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_plan_chatbot" {
  name   = "terraform-plan-chatbot"
  role   = aws_iam_role.github_actions_terraform_plan.id
  policy = data.aws_iam_policy_document.github_actions_terraform_plan_chatbot.json
}

# --- Toggle role: chatbot-toggle.yml flips the on/off flag, and nothing
# else. ---

data "aws_iam_policy_document" "github_actions_chatbot_toggle_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to its own GitHub Environment, with the same immutable-ID
    # wildcards as the apply role. Only a job that declares
    # `environment: ${var.chatbot_toggle_environment}` can assume it.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repository)[0]}*/${split("/", var.github_repository)[1]}*:environment:${var.chatbot_toggle_environment}"]
    }
  }
}

resource "aws_iam_role" "github_actions_chatbot_toggle" {
  name               = "github-actions-chatbot-toggle"
  assume_role_policy = data.aws_iam_policy_document.github_actions_chatbot_toggle_trust.json
}

data "aws_iam_policy_document" "github_actions_chatbot_toggle" {
  statement {
    sid       = "FlipChatbotFlag"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [local.chatbot_flag_arn]
  }
}

resource "aws_iam_role_policy" "github_actions_chatbot_toggle" {
  name   = "chatbot-toggle"
  role   = aws_iam_role.github_actions_chatbot_toggle.id
  policy = data.aws_iam_policy_document.github_actions_chatbot_toggle.json
}

# --- Owner alerts. They live here rather than in live/prod because the
# alert email must never be committed to this public repo: bootstrap is
# applied locally, with the address in a gitignored terraform.tfvars. ---

resource "aws_sns_topic" "owner_alerts" {
  name = "ae-rv-owner-alerts"
}

# AWS emails a confirmation link; alerts only flow once it's clicked.
resource "aws_sns_topic_subscription" "owner_alerts_email" {
  topic_arn = aws_sns_topic.owner_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Account-wide monthly cost budget, a backstop behind the chatbot's own
# daily quota and spike alarm.
resource "aws_budgets_budget" "monthly" {
  name         = "ae-rv-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
