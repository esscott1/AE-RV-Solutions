data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.project_name}-tfstate-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # Holds every stack's state. To tear it down deliberately, remove this in
  # its own change first.
  lifecycle {
    prevent_destroy = true
  }
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

# No thumbprint_list. AWS validates GitHub's OIDC endpoint against its own
# trusted CA library and ignores thumbprints for it, and the argument is
# optional + computed, so AWS keeps the value already stored. The old
# tls_certificate lookup computed it from whatever certificate this machine
# saw, and a TLS-intercepting antivirus substituted its own forged cert's
# fingerprint.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
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

# --- Read-only plan role: lets terraform-aws-plan.yml run `terraform plan`
# on pull requests. ---

data "aws_iam_policy_document" "github_actions_plan_trust" {
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

    # The repo-wide pull_request subject, with the same wildcards as the apply
    # role above to match GitHub's immutable-ID sub format. The repo is
    # public, but fork PRs never receive an OIDC token, so only branches in
    # this repo can reach this role. Any workflow on such a branch can,
    # though, which is why everything below is read-only (apart from the
    # state lock object).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repository)[0]}*/${split("/", var.github_repository)[1]}*:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform_plan" {
  name               = "github-actions-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.github_actions_plan_trust.json
}

data "aws_iam_policy_document" "github_actions_terraform_plan" {
  statement {
    sid       = "ReadProdState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/live/prod/terraform.tfstate"]
  }

  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  # Native S3 locking (use_lockfile) writes and then deletes this one object,
  # so plan needs to write it. This is the only write access the role has.
  statement {
    sid    = "ProdStateLock"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/live/prod/terraform.tfstate.tflock"]
  }

  # Refresh reads only, scoped to the one app and zone live/prod manages.
  # When the first plan hits an AccessDenied, add the exact action it names
  # rather than widening to a wildcard.
  statement {
    sid    = "ReadAmplifyApp"
    effect = "Allow"
    actions = [
      "amplify:GetApp",
      "amplify:GetBranch",
      "amplify:GetDomainAssociation",
      "amplify:ListTagsForResource",
    ]
    resources = [
      "arn:aws:amplify:${var.region}:${data.aws_caller_identity.current.account_id}:apps/${var.amplify_app_id}",
      "arn:aws:amplify:${var.region}:${data.aws_caller_identity.current.account_id}:apps/${var.amplify_app_id}/*",
    ]
  }

  statement {
    sid       = "ReadAmplifyWebhook"
    effect    = "Allow"
    actions   = ["amplify:GetWebhook"]
    resources = ["arn:aws:amplify:${var.region}:${data.aws_caller_identity.current.account_id}:webhooks/*"]
  }

  # Route 53 is global: no region or account in the ARN.
  statement {
    sid    = "ReadHostedZone"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListTagsForResource",
    ]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.github_actions_terraform_plan.id
  policy = data.aws_iam_policy_document.github_actions_terraform_plan.json
}
