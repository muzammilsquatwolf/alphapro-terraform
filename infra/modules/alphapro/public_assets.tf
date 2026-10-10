###############################################################################
# Public assets — sitemaps and feeds served from the EXISTING assets bucket.
#
# CloudFront reads through Origin Access Control, so the bucket keeps all four
# public-access blocks and gains no anonymous endpoint. OAC signs its requests
# as a principal; it does not need the bucket to be public.
#
# The important restraint is origin_path. The assets bucket is the
# application's general working store, and a distribution rooted at "/" would
# publish everything in it. Rooted at /<prefix> it can reach that prefix and
# nothing else, and the bucket policy is scoped to the same prefix — so the
# limit holds even if someone later changes the distribution.
###############################################################################

locals {
  enable_public_assets = var.enable_public_assets

  # An alias needs both a hostname and a certificate CloudFront can serve;
  # without either it falls back to its *.cloudfront.net domain.
  public_assets_alias = var.public_assets_certificate_arn != "" && var.public_assets_host != ""

  # Base URL for anything written under the public prefix.
  #
  # Keyed off public_assets_host alone, NOT off whether the alias is live. A
  # sitemap is read by crawlers and quoted in robots.txt, so the URL baked into
  # it has to be where it will permanently live — swapping from a
  # *.cloudfront.net address later would invalidate every URL already
  # published. Environments without a hostname fall back to the CloudFront
  # domain, which is resolvable and correct there.
  public_assets_env = local.enable_public_assets ? [
    {
      name  = "SITEMAP_PUBLIC_BASE"
      value = "https://${var.public_assets_host != "" ? var.public_assets_host : one(aws_cloudfront_distribution.public_assets[*].domain_name)}"
    }
  ] : []
}

resource "aws_cloudfront_origin_access_control" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  name                              = "${local.name_prefix}-public-assets"
  description                       = "OAC for the ${var.public_assets_prefix}/ prefix of ${aws_s3_bucket.assets.id}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Short TTLs rather than the managed CachingOptimized policy (1 day default).
# A feed that regenerates nightly and caches for a day is wrong half the time,
# and invalidating on every write is more machinery than it saves. Five minutes
# sits well inside how often Facebook refetches a catalogue.
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

resource "aws_cloudfront_distribution" "public_assets" {
  count = local.enable_public_assets ? 1 : 0

  enabled     = true
  comment     = "${local.name_prefix} public assets"
  price_class = "PriceClass_All"

  # Only claimed when a certificate exists — CloudFront refuses an alias it
  # cannot serve TLS for.
  aliases = local.public_assets_alias ? [var.public_assets_host] : []

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.public_assets[0].id

    # Everything outside this prefix is unreachable through the distribution.
    origin_path = "/${var.public_assets_prefix}"
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.public_assets[0].id

    # Sitemaps and feeds are XML or CSV — this is most of the bandwidth.
    compress = true
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

# Scoped to the prefix, not the bucket. This is the second half of the
# containment: origin_path decides what CloudFront asks for, this decides what
# S3 will answer. Either alone could be widened by accident; both together
# means two deliberate changes.
resource "aws_s3_bucket_policy" "assets_public_prefix" {
  count = local.enable_public_assets ? 1 : 0

  bucket = aws_s3_bucket.assets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontReadPublicPrefix"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.assets.arn}/${var.public_assets_prefix}/*"
        Condition = {
          StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.public_assets[0].arn }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.assets]
}
