# --- Employee API Lambdas ------------------------------------------------------

locals {
  # The switches the admin Feature Mgr page can flip: those passed in
  # (Eddie's), plus Herman's, which this module owns.
  feature_flags = merge(var.feature_flags, { herman = aws_ssm_parameter.herman_enabled.name })

  # Herman's model as his log lines record it: the inference profile's ID,
  # after the ARN's last /. AI Stats prices his turns with it.
  herman_model = element(split("/", var.model_id), length(split("/", var.model_id)) - 1)
}

# One zip of lambda/ for every function: they share claims.py. output_file_mode
# pins the files' permissions, so a plan run on Windows builds the same zip
# (and hash) as CI on Linux.
data "archive_file" "lambda" {
  type             = "zip"
  source_dir       = "${path.module}/lambda"
  excludes         = ["__pycache__"]
  output_path      = "${path.module}/.build/lambda.zip"
  output_file_mode = "0644"
}

# --- GET /me -------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "me" {
  name               = "${var.name_prefix}-me"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

# Writes its own logs, and nothing else.
data "aws_iam_policy_document" "me" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.me.arn}:*"]
  }
}

resource "aws_iam_role_policy" "me" {
  name   = "logs"
  role   = aws_iam_role.me.id
  policy = data.aws_iam_policy_document.me.json
}

# Created here, before the function, so it has a retention period and tags
# rather than the never-expiring group Lambda would create on first run.
resource "aws_cloudwatch_log_group" "me" {
  name              = "/aws/lambda/${var.name_prefix}-me"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "me" {
  function_name    = "${var.name_prefix}-me"
  description      = "GET /me on the employee API: who's signed in, and the Employees' Space content."
  role             = aws_iam_role.me.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "me.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 128
  timeout          = 5
  tags             = var.tags

  depends_on = [aws_cloudwatch_log_group.me, aws_iam_role_policy.me]
}

resource "aws_lambda_permission" "me" {
  statement_id  = "AllowEmployeeApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.me.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.employees.execution_arn}/*/GET/me"
}

# --- /admin/* (admins only) ---------------------------------------------------------

resource "aws_iam_role" "admin" {
  name               = "${var.name_prefix}-admin"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

# Reads chat transcripts and the chat API's daily usage, and reads and flips
# the feature switches in var.feature_flags (the Feature Mgr page). It can't
# change anything else.
data "aws_iam_policy_document" "admin" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.admin.arn}:*"]
  }

  statement {
    sid       = "ListTranscripts"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.transcripts_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["transcripts/*"]
    }
  }

  statement {
    sid       = "ReadTranscripts"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.transcripts_bucket}/transcripts/*"]
  }

  statement {
    sid     = "ReadChatUsage"
    actions = ["apigateway:GET"]
    resources = [
      "arn:aws:apigateway:${local.region}::/usageplans/${var.usage_plan_id}",
      "arn:aws:apigateway:${local.region}::/usageplans/${var.usage_plan_id}/usage",
    ]
  }

  # Only the switches' own parameters: their history (which includes the
  # current value) and overwriting the value.
  dynamic "statement" {
    for_each = length(local.feature_flags) > 0 ? [1] : []
    content {
      sid       = "FeatureFlags"
      actions   = ["ssm:GetParameterHistory", "ssm:PutParameter"]
      resources = [for name in values(local.feature_flags) : "arn:aws:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${name}"]
    }
  }

  # Herman's usage on AI Stats (herman_usage.py): a Logs Insights query over
  # his log group only. Reading and stopping a query can't be scoped to a
  # log group.
  statement {
    sid       = "QueryHermanLogs"
    actions   = ["logs:StartQuery"]
    resources = ["${aws_cloudwatch_log_group.assistant.arn}:*"]
  }

  statement {
    sid       = "ReadQueryResults"
    actions   = ["logs:GetQueryResults", "logs:StopQuery"]
    resources = ["*"]
  }

  # Herman's usage shows each employee's current email, looked up by sub in
  # the employee pool only.
  statement {
    sid       = "LookUpEmployees"
    actions   = ["cognito-idp:ListUsers"]
    resources = [aws_cognito_user_pool.employees.arn]
  }
}

resource "aws_iam_role_policy" "admin" {
  name   = "admin"
  role   = aws_iam_role.admin.id
  policy = data.aws_iam_policy_document.admin.json
}

resource "aws_cloudwatch_log_group" "admin" {
  name              = "/aws/lambda/${var.name_prefix}-admin"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "admin" {
  function_name    = "${var.name_prefix}-admin"
  description      = "/admin/* on the employee API, for admins: Eddie's and Herman's usage, Eddie's conversations, and the feature switches."
  role             = aws_iam_role.admin.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "admin.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 256
  timeout          = 20
  tags             = var.tags

  environment {
    variables = {
      TRANSCRIPTS_BUCKET    = var.transcripts_bucket
      USAGE_PLAN_ID         = var.usage_plan_id
      API_KEY_ID            = var.api_key_id
      PRICE_PER_MTOK_INPUT  = tostring(var.price_per_mtok_input)
      PRICE_PER_MTOK_OUTPUT = tostring(var.price_per_mtok_output)
      # The Feature Mgr page (features.py): which parameter each switch is, and
      # the roles its history is attributed to.
      FEATURE_FLAGS           = jsonencode(local.feature_flags)
      ADMIN_ROLE_NAME         = aws_iam_role.admin.name
      FLAG_WORKFLOW_ROLE_NAME = var.flag_workflow_role_name
      TERRAFORM_ROLE_NAME     = var.terraform_role_name
      # Herman's usage (herman_usage.py): where his log lines are, the model
      # older lines are counted as, and prices per model. He uses the same
      # model as Eddie, so the same prices.
      HERMAN_LOG_GROUP = aws_cloudwatch_log_group.assistant.name
      HERMAN_MODEL     = local.herman_model
      HERMAN_PRICES    = jsonencode({ (local.herman_model) = [var.price_per_mtok_input, var.price_per_mtok_output] })
      # Where herman_usage.py looks up each employee's current email.
      USER_POOL_ID = aws_cognito_user_pool.employees.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.admin, aws_iam_role_policy.admin]
}

resource "aws_lambda_permission" "admin" {
  statement_id  = "AllowEmployeeApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.admin.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.employees.execution_arn}/*/*/admin/*"
}

# --- /kb/* (knowledge administration) ---------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "kb" {
  name               = "${var.name_prefix}-kb"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

# The documents bucket's pending/, rejected/ and approved/ prefixes, and the
# knowledge base's ingestion jobs, and nothing else.
data "aws_iam_policy_document" "kb" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.kb.arn}:*"]
  }

  statement {
    sid       = "ListKnowledge"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.kb_docs_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["pending/*", "rejected/*", "approved/*"]
    }
  }

  statement {
    sid     = "ManageKnowledge"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.kb_docs_bucket}/pending/*",
      "arn:aws:s3:::${var.kb_docs_bucket}/rejected/*",
      "arn:aws:s3:::${var.kb_docs_bucket}/approved/*",
    ]
  }

  statement {
    sid       = "IndexKnowledge"
    actions   = ["bedrock:StartIngestionJob", "bedrock:GetIngestionJob", "bedrock:ListIngestionJobs"]
    resources = ["arn:aws:bedrock:${local.region}:${data.aws_caller_identity.current.account_id}:knowledge-base/${var.knowledge_base_id}"]
  }
}

resource "aws_iam_role_policy" "kb" {
  name   = "knowledge"
  role   = aws_iam_role.kb.id
  policy = data.aws_iam_policy_document.kb.json
}

resource "aws_cloudwatch_log_group" "kb" {
  name              = "/aws/lambda/${var.name_prefix}-kb"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "kb" {
  function_name    = "${var.name_prefix}-kb"
  description      = "/kb/* on the employee API: submit, review, publish, view and remove knowledge-base entries."
  role             = aws_iam_role.kb.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "kb.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 256
  timeout          = 30
  tags             = var.tags

  environment {
    variables = {
      KB_DOCS_BUCKET    = var.kb_docs_bucket
      KNOWLEDGE_BASE_ID = var.knowledge_base_id
      KB_DATA_SOURCE_ID = var.kb_data_source_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.kb, aws_iam_role_policy.kb]
}

resource "aws_lambda_permission" "kb" {
  statement_id  = "AllowEmployeeApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kb.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.employees.execution_arn}/*/*/kb/*"
}

# --- /assistant/* (Herman, the employee assistant) ------------------------------------

# Herman's on/off switch, flipped on the admin Feature Mgr page (features.py)
# and read by the function on every request. Like Eddie's, it's created on and
# then changed outside Terraform, so its value and the page's who-changed-it
# note are ignored: applies never undo a change.
resource "aws_ssm_parameter" "herman_enabled" {
  name        = var.herman_flag_name
  description = "Herman on/off switch: \"true\" or \"false\". Flip it on the Feature Mgr admin page."
  type        = "String"
  value       = "true"
  tags        = var.tags

  lifecycle {
    ignore_changes = [value, description]
  }
}

resource "aws_iam_role" "assistant" {
  name               = "${var.name_prefix}-assistant"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

# Its own logs, the model, and reading his on/off switch, and nothing else.
# Herman only drafts: the employee submits through /kb/entries, so he needs
# no access to the documents bucket. Later modes (work orders, invoices) add
# their own statements here.
data "aws_iam_policy_document" "assistant" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.assistant.arn}:*"]
  }

  statement {
    sid       = "InvokeModel"
    actions   = ["bedrock:InvokeModel"]
    resources = var.model_invoke_arns
  }

  statement {
    sid       = "ReadSwitch"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.herman_enabled.arn]
  }
}

resource "aws_iam_role_policy" "assistant" {
  name   = "assistant"
  role   = aws_iam_role.assistant.id
  policy = data.aws_iam_policy_document.assistant.json
}

resource "aws_cloudwatch_log_group" "assistant" {
  name              = "/aws/lambda/${var.name_prefix}-assistant"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "assistant" {
  function_name    = "${var.name_prefix}-assistant"
  description      = "/assistant/* on the employee API: Herman, who interviews employees and drafts knowledge that teaches Eddie."
  role             = aws_iam_role.assistant.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "assistant.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 256
  # The HTTP API waits at most 30 seconds for an integration.
  timeout = 29
  tags    = var.tags

  environment {
    variables = {
      MODEL_ID    = var.model_id
      HERMAN_FLAG = aws_ssm_parameter.herman_enabled.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.assistant, aws_iam_role_policy.assistant]
}

resource "aws_lambda_permission" "assistant" {
  statement_id  = "AllowEmployeeApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.assistant.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.employees.execution_arn}/*/*/assistant/*"
}
