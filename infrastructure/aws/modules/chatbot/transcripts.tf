# --- Chat transcripts ---------------------------------------------------------
#
# Every chat exchange is saved as one JSON file by the state machine's Record
# state: transcripts/YYYY/MM/DD/HHMMSS-<execution>.json (UTC). Each file holds
# the conversation the widget sent (at most max_messages), Eddie's reply, the
# route and source label, and token counts. Nothing that identifies a
# visitor is stored: the API forwards only the messages.
#
# S3 rather than DynamoDB: at the 50-a-day quota both cost well under a cent a
# month, and files are simpler to expire, browse, and download. The Admin
# page (later) lists a day's folder and reads its files.

locals {
  transcripts_bucket_name = "${var.name_prefix}-transcripts-${local.account_id}"
  transcripts_prefix      = "transcripts/"
}

# No prevent_destroy or versioning: transcripts are disposable and expire on
# their own, and a deleted transcript should stay deleted.
resource "aws_s3_bucket" "transcripts" {
  bucket = local.transcripts_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "transcripts" {
  bucket                  = aws_s3_bucket.transcripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id

  rule {
    id     = "expire-transcripts"
    status = "Enabled"

    filter {
      prefix = local.transcripts_prefix
    }

    expiration {
      days = var.transcript_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
