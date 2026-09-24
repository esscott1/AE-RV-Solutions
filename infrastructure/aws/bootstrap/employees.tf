# --- Employee sign-in (modules/employees): CI permissions. ---
#
# Same rules as chatbot.tf: scoped to var.employees_name_prefix where the
# service allows it, and when a CI plan or apply hits an AccessDenied, add
# the exact action it names and re-apply bootstrap locally.
#
# User pool ARNs contain generated IDs, not names, so pool actions can only
# be scoped to this account's userpool/*. This account holds only this
# project's pool, and creating one requires the Customer tag.

locals {
  employees_prefix = var.employees_name_prefix

  employees_user_pool_arn = "arn:aws:cognito-idp:${var.region}:${local.account_id}:userpool/*"
  employees_function_arn  = "arn:aws:lambda:${var.region}:${local.account_id}:function:${local.employees_prefix}-*"
  employees_role_arn      = "arn:aws:iam::${local.account_id}:role/${local.employees_prefix}-*"
  employees_log_group_arn = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.employees_prefix}-*"

  # HTTP API resources have no account in their ARN, so API Gateway access
  # can only be scoped to these paths. Tags use /tags/*, already granted in
  # chatbot.tf.
  employees_apigateway_arns = [
    "arn:aws:apigateway:${var.region}::/apis",
    "arn:aws:apigateway:${var.region}::/apis/*",
  ]

  employees_user_pool_read_actions = [
    "cognito-idp:DescribeUserPool",
    "cognito-idp:GetUserPoolMfaConfig",
    "cognito-idp:DescribeUserPoolClient",
    "cognito-idp:ListUserPoolClients",
    "cognito-idp:GetGroup",
    "cognito-idp:DescribeManagedLoginBranding",
    "cognito-idp:DescribeManagedLoginBrandingByClient",
    "cognito-idp:ListTagsForResource",
  ]

  employees_function_read_actions = [
    "lambda:GetFunction",
    "lambda:GetFunctionConfiguration",
    "lambda:GetFunctionCodeSigningConfig",
    "lambda:GetFunctionConcurrency",
    "lambda:GetFunctionRecursionConfig",
    "lambda:GetRuntimeManagementConfig",
    "lambda:GetPolicy",
    "lambda:ListVersionsByFunction",
    "lambda:ListTags",
  ]
}

# --- Apply role ----------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_terraform_employees" {
  # Only a pool carrying the project's Customer tag can be created.
  statement {
    sid       = "CreateEmployeeUserPool"
    effect    = "Allow"
    actions   = ["cognito-idp:CreateUserPool"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Customer"
      values   = ["AERVSolutions"]
    }
  }

  statement {
    sid    = "ManageEmployeeUserPool"
    effect = "Allow"
    actions = concat(local.employees_user_pool_read_actions, [
      "cognito-idp:UpdateUserPool",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:UpdateUserPoolDomain",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:CreateGroup",
      "cognito-idp:UpdateGroup",
      "cognito-idp:DeleteGroup",
      "cognito-idp:CreateManagedLoginBranding",
      "cognito-idp:UpdateManagedLoginBranding",
      "cognito-idp:DeleteManagedLoginBranding",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
    ])
    resources = [local.employees_user_pool_arn]
  }

  # Creating a tagged HTTP API stage also calls apigateway:TagResource on
  # /apis/<id>/stages (found by the first apply's AccessDenied).
  statement {
    sid    = "ManageEmployeeApi"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = local.employees_apigateway_arns
  }

  statement {
    sid    = "ManageEmployeeFunctions"
    effect = "Allow"
    actions = concat(local.employees_function_read_actions, [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
    ])
    resources = [local.employees_function_arn]
  }

  statement {
    sid    = "ManageEmployeeRoles"
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
    resources = [local.employees_role_arn]
  }

  statement {
    sid       = "PassEmployeeRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.employees_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid    = "ManageEmployeeLogGroups"
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
    resources = [local.employees_log_group_arn, "${local.employees_log_group_arn}:*"]
  }

  # Calls AWS only authorizes on "*" (log groups: DescribeLogGroups is
  # already granted in chatbot.tf).
  statement {
    sid       = "DescribeEmployeeUserPoolDomain"
    effect    = "Allow"
    actions   = ["cognito-idp:DescribeUserPoolDomain"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_employees" {
  name   = "terraform-apply-employees"
  role   = aws_iam_role.github_actions_terraform.id
  policy = data.aws_iam_policy_document.github_actions_terraform_employees.json
}

# --- Plan role: the read-only counterpart ---------------------------------------

data "aws_iam_policy_document" "github_actions_terraform_plan_employees" {
  statement {
    sid       = "ReadEmployeeUserPool"
    effect    = "Allow"
    actions   = local.employees_user_pool_read_actions
    resources = [local.employees_user_pool_arn]
  }

  statement {
    sid       = "ReadEmployeeApi"
    effect    = "Allow"
    actions   = ["apigateway:GET"]
    resources = local.employees_apigateway_arns
  }

  statement {
    sid       = "ReadEmployeeFunctions"
    effect    = "Allow"
    actions   = local.employees_function_read_actions
    resources = [local.employees_function_arn]
  }

  statement {
    sid       = "ReadEmployeeRoles"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = [local.employees_role_arn]
  }

  statement {
    sid       = "ReadEmployeeLogGroups"
    effect    = "Allow"
    actions   = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"]
    resources = [local.employees_log_group_arn, "${local.employees_log_group_arn}:*"]
  }

  statement {
    sid       = "DescribeEmployeeUserPoolDomain"
    effect    = "Allow"
    actions   = ["cognito-idp:DescribeUserPoolDomain"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_plan_employees" {
  name   = "terraform-plan-employees"
  role   = aws_iam_role.github_actions_terraform_plan.id
  policy = data.aws_iam_policy_document.github_actions_terraform_plan_employees.json
}
