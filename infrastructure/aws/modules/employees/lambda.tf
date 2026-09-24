# --- GET /me Lambda -----------------------------------------------------------

data "archive_file" "me" {
  type        = "zip"
  source_file = "${path.module}/lambda/me.py"
  output_path = "${path.module}/.build/me.zip"
}

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
  filename         = data.archive_file.me.output_path
  source_code_hash = data.archive_file.me.output_base64sha256
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
