data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.project_name}-tfstate-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- GitHub Actions OIDC: lets terraform-aws.yml assume an AWS role without
# any stored long-lived access keys. ---

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_trust" {
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

    # Scoped to a GitHub Environment, not the repo-wide `pull_request`
    # subject (which every pull_request-triggered workflow in the repo
    # shares) - only a job that declares `environment: ${var.github_environment}`
    # can assume this role.
    #
    # StringLike (not StringEquals) because GitHub's actual sub claim was
    # observed (via CloudTrail, after a real AssumeRoleWithWebIdentity
    # AccessDenied) to be
    # "repo:OWNER@<owner-id>/REPO@<repo-id>:environment:NAME" - the
    # "immutable ID" format - not the plain "repo:OWNER/REPO:environment:NAME"
    # the docs read for this project implied. The wildcards match both
    # forms so this doesn't silently break if GitHub's default changes
    # again.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repository)[0]}*/${split("/", var.github_repository)[1]}*:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform" {
  name               = "github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

data "aws_iam_policy_document" "github_actions_terraform" {
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid    = "TerraformStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.tfstate_lock.arn]
  }

  statement {
    sid       = "ManageAmplify"
    effect    = "Allow"
    actions   = ["amplify:*"]
    resources = ["*"]
  }

  # Two distinct needs are covered here. The first block of actions lets
  # Terraform manage the hosted zone resource itself. The rest are needed
  # because Amplify Hosting has no service-linked role and uses forward
  # access sessions - so when it writes the domain's validation and routing
  # records, that write is authorized against THIS role, not against a role
  # of Amplify's own.
  #
  # Route 53 is a global service: these must not be region-scoped.
  #
  # No acm:* actions are needed. The certificate is AMPLIFY_MANAGED
  # (confirmed live), and AWS's own AdministratorAccess-Amplify policy
  # likewise contains no ACM actions.
  statement {
    sid    = "ManageRoute53"
    effect = "Allow"
    actions = [
      "route53:CreateHostedZone",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListTagsForResource",
      "route53:ChangeTagsForResource",
      "route53:UpdateHostedZoneComment",
      "route53:DeleteHostedZone",
      "route53:GetChange",
      "route53:ListResourceRecordSets",
      "route53:ChangeResourceRecordSets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name   = "terraform-apply"
  role   = aws_iam_role.github_actions_terraform.id
  policy = data.aws_iam_policy_document.github_actions_terraform.json
}
