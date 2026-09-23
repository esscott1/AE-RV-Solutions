# --- Knowledge base (v2) -----------------------------------------------------
#
# The owner's own FAQs, notes, capability pages, and diagram descriptions
# live in a private S3 bucket. They're never in this public repo. A "sync"
# (chatbot-kb-sync.yml, or Sync in the Bedrock console) chunks them, embeds
# them with Titan Text Embeddings V2, and stores the vectors in S3 Vectors.
# The chatbot's Answer step retrieves the few most relevant passages per
# question.
#
# Terraform owns the containers (bucket, vector store, knowledge base), not
# the content. Uploading or changing documents needs no PR or deploy.

locals {
  kb_docs_bucket_name = "${var.name_prefix}-kb-docs-${local.account_id}"
  kb_vector_bucket    = "${var.name_prefix}-kb-vectors"
  kb_index_name       = "${var.name_prefix}-kb-index"
  embedding_model_arn = "arn:aws:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"
}

# --- Documents bucket (the owner's content) -----------------------------

resource "aws_s3_bucket" "kb_docs" {
  bucket = local.kb_docs_bucket_name
  tags   = var.tags

  # Holds the owner's own writing. To remove it deliberately, remove this in
  # its own PR first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "kb_docs" {
  bucket                  = aws_s3_bucket.kb_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "kb_docs" {
  bucket = aws_s3_bucket.kb_docs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kb_docs" {
  bucket = aws_s3_bucket.kb_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning keeps every earlier copy of a document, so an accidental
# overwrite or delete can be undone from the console (Show versions).
resource "aws_s3_bucket_versioning" "kb_docs" {
  bucket = aws_s3_bucket.kb_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# --- Vector store (S3 Vectors) -----------------------------------------------

# Derived data: a sync rebuilds it entirely from the documents bucket, so it
# isn't protected like the documents.
resource "aws_s3vectors_vector_bucket" "kb" {
  vector_bucket_name = local.kb_vector_bucket
  tags               = var.tags
}

resource "aws_s3vectors_index" "kb" {
  vector_bucket_name = aws_s3vectors_vector_bucket.kb.vector_bucket_name
  index_name         = local.kb_index_name
  data_type          = "float32"
  dimension          = var.embedding_dimensions # Titan Text Embeddings V2
  distance_metric    = "cosine"
  tags               = var.tags

  # Bedrock stores each chunk's text and its metadata alongside the vector.
  # Marking them non-filterable lifts the small filterable-metadata size
  # limit, which chunk text would otherwise exceed.
  metadata_configuration {
    non_filterable_metadata_keys = ["AMAZON_BEDROCK_TEXT", "AMAZON_BEDROCK_METADATA"]
  }
}

# --- Knowledge base and its data source -----------------------------------

data "aws_iam_policy_document" "kb_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "kb" {
  name               = "${var.name_prefix}-kb"
  assume_role_policy = data.aws_iam_policy_document.kb_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "kb" {
  statement {
    sid       = "ReadDocuments"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.kb_docs.arn]
  }

  statement {
    sid       = "ReadDocumentObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.kb_docs.arn}/*"]
  }

  statement {
    sid       = "Embed"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.embedding_model_arn]
  }

  statement {
    sid = "VectorIndex"
    actions = [
      "s3vectors:PutVectors",
      "s3vectors:GetVectors",
      "s3vectors:DeleteVectors",
      "s3vectors:QueryVectors",
      "s3vectors:GetIndex",
    ]
    resources = [aws_s3vectors_index.kb.index_arn]
  }
}

resource "aws_iam_role_policy" "kb" {
  name   = "knowledge-base"
  role   = aws_iam_role.kb.id
  policy = data.aws_iam_policy_document.kb.json
}

resource "aws_bedrockagent_knowledge_base" "kb" {
  name        = "${var.name_prefix}-kb"
  description = "A&E RV Solutions chatbot knowledge: the owner's FAQs, notes, capability pages, and diagram descriptions."
  role_arn    = aws_iam_role.kb.arn
  tags        = var.tags

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn
      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions          = var.embedding_dimensions
          embedding_data_type = "FLOAT32"
        }
      }
    }
  }

  storage_configuration {
    type = "S3_VECTORS"
    s3_vectors_configuration {
      index_arn = aws_s3vectors_index.kb.index_arn
    }
  }

  # Bedrock checks the role's access when creating the knowledge base, so
  # the policy must be in place first.
  depends_on = [aws_iam_role_policy.kb]
}

resource "aws_bedrockagent_data_source" "kb_docs" {
  name              = "${var.name_prefix}-kb-docs"
  knowledge_base_id = aws_bedrockagent_knowledge_base.kb.id

  # RETAIN: deleting this data source leaves its vectors in place instead of
  # failing on or wiping the index; a later sync reconciles them.
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.kb_docs.arn
    }
  }

  # About 300-token passages with 20% overlap: Bedrock's default, which
  # suits short Markdown pages (one FAQ answer or one capability section
  # per chunk).
  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }
}
