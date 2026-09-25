# --- Employee API Lambdas ------------------------------------------------------
#
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

# --- GET /admin/* (admins only) --------------------------------------------------

resource "aws_iam_role" "admin" {
  name               = "${var.name_prefix}-admin"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

# Read-only: list and read chat transcripts, and read the chat API's daily
# usage. It can't change or delete anything.
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
}

resource "aws_iam_role_policy" "admin" {
  name   = "admin-read"
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
  description      = "GET /admin/usage and /admin/conversations on the employee API: Eddie's usage and chat conversations, for admins."
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
    }
  }

  depends_on = [aws_cloudwatch_log_group.admin, aws_iam_role_policy.admin]
}

resource "aws_lambda_permission" "admin" {
  statement_id  = "AllowEmployeeApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.admin.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.employees.execution_arn}/*/GET/admin/*"
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
