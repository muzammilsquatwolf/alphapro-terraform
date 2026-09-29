###############################################################################
# Terraform state buckets — one per environment
###############################################################################

resource "aws_s3_bucket" "state" {
  for_each = toset(var.state_bucket_names)

  bucket = each.value

  tags = { Name = each.value }

  # Destroying a state bucket orphans the record of every resource the matching
  # environment manages. Deliberate decommission means removing this block
  # first, on purpose.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the important one: it's what lets you recover from a corrupted
# or truncated state write, which is the failure mode that actually hurts.
resource "aws_s3_bucket_versioning" "state" {
  for_each = aws_s3_bucket.state

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  for_each = aws_s3_bucket.state

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State files contain resource attributes in plaintext — including the RDS
# master password. Nothing about a state bucket should ever be public.
resource "aws_s3_bucket_public_access_block" "state" {
  for_each = aws_s3_bucket.state

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# State lock table — shared across environments
###############################################################################

resource "aws_dynamodb_table" "locks" {
  name = var.lock_table_name

  # On-demand: locking is a handful of writes per apply, so provisioned
  # capacity would be pure waste.
  billing_mode = "PAY_PER_REQUEST"

  # Terraform's S3 backend hardcodes this attribute name — it is not
  # configurable. A different name silently fails to lock.
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Name = var.lock_table_name }

  lifecycle {
    prevent_destroy = true
  }
}
