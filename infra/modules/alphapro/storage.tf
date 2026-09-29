###############################################################################
# S3 - application asset storage, read/written/deleted directly by ECS tasks.
# Bucket names are globally unique across all of AWS, so this is always an
# explicit var, never derived from local.name_prefix.
###############################################################################

resource "aws_s3_bucket" "assets" {
  bucket = var.s3_bucket_name

  tags = merge(local.default_tags, { Name = var.s3_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
