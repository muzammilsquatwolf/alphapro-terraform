###############################################################################
# Public assets — sitemaps, product feeds, anything a crawler must fetch.
#
# Separate from the assets bucket on purpose. That one is the application's
# private working store: all four public-access blocks on, and the task role
# holds PutObject/GetObject/DeleteObject across the whole thing. Serving
# anything from it would mean lifting restrict_public_buckets, which is
# bucket-wide — and after that the only thing keeping the app's private objects
# private is a policy nobody is going to re-read. Two buckets makes the mistake
# impossible rather than merely unlikely.
#
# This bucket is ALSO not public. It sits behind CloudFront with Origin Access
# Control: CloudFront is the only principal the bucket policy admits, so there
# is no anonymous S3 endpoint to find, enumerate or bypass the CDN with.
#
# Empty public_assets_bucket_name disables the whole thing, the same way an
# empty image disables the frontend.
###############################################################################

locals {
  enable_public_assets = var.public_assets_bucket_name != ""

  # An alias needs both a hostname and a certificate CloudFront can serve;
  # without either it falls back to its *.cloudfront.net domain.
  public_assets_alias = var.public_assets_certificate_arn != "" && var.public_assets_host != ""

  # Base URL for anything written into the public bucket — sitemaps, feeds.
  # Built from whichever hostname actually serves the distribution rather than
  # written out by hand: the custom host when a certificate makes it claimable,
  # the *.cloudfront.net domain otherwise. A literal would be wrong in dev,
  # wrong before the certificate lands, and silently stale after either changes.
  #
  # Empty list when public assets are off, so the variable is absent rather
  # than set to a URL that resolves to nothing.
  public_assets_env = local.enable_public_assets ? [
    {
      name  = "SITEMAP_PUBLIC_BASE"
      value = "https://${local.public_assets_alias ? var.public_assets_host : one(aws_cloudfront_distribution.public_assets[*].domain_name)}"
    }
  ] : []
}

resource "aws_s3_bucket" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  bucket = var.public_assets_bucket_name

  tags = merge(local.default_tags, { Name = var.public_assets_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  bucket = aws_s3_bucket.public_assets[0].id

  # All four stay on. "Public" here means reachable through CloudFront, not
  # readable straight off S3.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  bucket = aws_s3_bucket.public_assets[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  name                              = "${local.name_prefix}-public-assets"
  description                       = "OAC for ${var.public_assets_bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Short TTLs rather than the managed CachingOptimized policy (1 day default).
# A feed that regenerates nightly and caches for a day is a feed that is wrong
# half the time, and invalidating on every write costs more thought than it
# saves. Five minutes is well inside how often Facebook refetches a catalogue.
resource "aws_cloudfront_cache_policy" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  name        = "${local.name_prefix}-public-assets"
  default_ttl = 300
  min_ttl     = 0
  max_ttl     = 3600

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

# One distribution serving the whole bucket. Each store writes under its own
# prefix, so URLs read asset.squatwolf.com/<store>/sitemap.xml — the paths do
# the separating rather than the hostnames.
resource "aws_cloudfront_distribution" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  enabled     = true
  comment     = "${local.name_prefix} public assets"
  price_class = "PriceClass_All"

  # Only claimed when a certificate exists — CloudFront refuses an alias it
  # cannot serve TLS for.
  aliases = local.public_assets_alias ? [var.public_assets_host] : []

  origin {
    domain_name              = aws_s3_bucket.public_assets[0].bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.public_assets[0].id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.public_assets[0].id
    compress               = true
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  dynamic "viewer_certificate" {
    for_each = local.public_assets_alias ? [1] : []
    content {
      acm_certificate_arn      = var.public_assets_certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.public_assets_alias ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  tags = local.default_tags
}

# CloudFront is the only principal allowed to read, and only this distribution.
resource "aws_s3_bucket_policy" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  bucket = aws_s3_bucket.public_assets[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.public_assets[0].arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.public_assets[0].arn }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.public_assets]
}

# Write and overwrite, but not delete. A stale feed is recoverable; a feed that
# vanished while Facebook was fetching it is a support ticket.
#
# A managed policy plus attachment, not an inline aws_iam_role_policy — the
# same shape as ecs_task_s3_assets. Inline policies need iam:PutRolePolicy,
# which the Terraform user does not have and would be a new grant for no gain.
resource "aws_iam_policy" "ecs_public_assets" {
  count = local.enable_public_assets ? 1 : 0

  name        = "${local.iam_prefix}-ecs-public-assets"
  description = "Allow ECS tasks to write sitemaps and feeds into the public assets bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.public_assets[0].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.public_assets[0].arn
      },
    ]
  })

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_public_assets" {
  count = local.enable_public_assets ? 1 : 0

  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_public_assets[0].arn
}
