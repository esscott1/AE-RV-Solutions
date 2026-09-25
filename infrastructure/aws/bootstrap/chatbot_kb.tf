# --- Chatbot knowledge base (modules/chatbot/kb.tf): CI permissions. ---
#
# (The repo-to-bucket sync role was removed on 2026-09-24: knowledge is now
# managed on the website, through modules/employees' knowledge API.)
#
# Same rules as chatbot.tf: scoped to the ae-rv-chatbot prefix where the
# service allows it, and when a CI plan or apply hits an AccessDenied, add
# the exact action it names.
#
# Knowledge base and data source ARNs contain generated IDs, not names, so
# they can only be scoped to this account's knowledge-base/*. This account
# holds only this project's knowledge base.

locals {
  kb_docs_bucket_arn = "arn:aws:s3:::${local.chatbot_prefix}-kb-docs-*"
  kb_vector_arns = [
    "arn:aws:s3vectors:${var.region}:${local.account_id}:bucket/${local.chatbot_prefix}-*",
    "arn:aws:s3vectors:${var.region}:${local.account_id}:bucket/${local.chatbot_prefix}-*/index/*",
  ]
  kb_arn = "arn:aws:bedrock:${var.region}:${local.account_id}:knowledge-base/*"
}

# --- Apply role ---------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_terraform_chatbot_kb" {
  # The documents bucket. Get* here is bucket-level only (the resource is the
  # bucket ARN, not its objects), which covers the many configuration reads
  # aws_s3_bucket performs. CI never reads or writes the documents.
  statement {
    sid    = "ManageKbDocsBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:Get*",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketTagging",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.kb_docs_bucket_arn]
  }

  statement {
    sid    = "ManageKbVectorStore"
    effect = "Allow"
    actions = [
      "s3vectors:CreateVectorBucket",
      "s3vectors:GetVectorBucket",
      "s3vectors:DeleteVectorBucket",
      "s3vectors:CreateIndex",
      "s3vectors:GetIndex",
      "s3vectors:DeleteIndex",
      "s3vectors:ListIndexes",
      "s3vectors:TagResource",
      "s3vectors:UntagResource",
      "s3vectors:ListTagsForResource",
    ]
    resources = local.kb_vector_arns
  }

  statement {
    sid    = "ManageKnowledgeBase"
    effect = "Allow"
    actions = [
      "bedrock:CreateKnowledgeBase",
      "bedrock:GetKnowledgeBase",
      "bedrock:UpdateKnowledgeBase",
      "bedrock:DeleteKnowledgeBase",
      "bedrock:CreateDataSource",
      "bedrock:GetDataSource",
      "bedrock:UpdateDataSource",
      "bedrock:DeleteDataSource",
      "bedrock:ListDataSources",
      "bedrock:TagResource",
      "bedrock:UntagResource",
      "bedrock:ListTagsForResource",
    ]
    resources = [local.kb_arn]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_chatbot_kb" {
  name   = "terraform-apply-chatbot-kb"
  role   = aws_iam_role.github_actions_terraform.id
  policy = data.aws_iam_policy_document.github_actions_terraform_chatbot_kb.json
}

# --- Plan role: read-only counterpart --------------------------------------

data "aws_iam_policy_document" "github_actions_terraform_plan_chatbot_kb" {
  statement {
    sid       = "ReadKbDocsBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:Get*"]
    resources = [local.kb_docs_bucket_arn]
  }

  statement {
    sid       = "ReadKbVectorStore"
    effect    = "Allow"
    actions   = ["s3vectors:GetVectorBucket", "s3vectors:GetIndex", "s3vectors:ListIndexes", "s3vectors:ListTagsForResource"]
    resources = local.kb_vector_arns
  }

  statement {
    sid       = "ReadKnowledgeBase"
    effect    = "Allow"
    actions   = ["bedrock:GetKnowledgeBase", "bedrock:GetDataSource", "bedrock:ListDataSources", "bedrock:ListTagsForResource"]
    resources = [local.kb_arn]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_plan_chatbot_kb" {
  name   = "terraform-plan-chatbot-kb"
  role   = aws_iam_role.github_actions_terraform_plan.id
  policy = data.aws_iam_policy_document.github_actions_terraform_plan_chatbot_kb.json
}
