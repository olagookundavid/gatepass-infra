# THE CDN: CloudFront in front of the images bucket, on the name cdn.<domain>.
#
# WHY A CDN. Event pictures are the same for every visitor. CloudFront keeps copies at edge
# locations near the visitor, so they load fast, S3 is asked rarely, and S3 itself can stay completely
# private. The page links to https://cdn.<domain>/images/events/<id>/<file> (CDN_BASE_URL).
#
# HOW IT READS A PRIVATE BUCKET: ORIGIN ACCESS CONTROL (OAC). CloudFront signs its requests to S3
# (SigV4) as the service principal cloudfront.amazonaws.com; the bucket policy below says "that
# principal may read images/*, but only when the request is made on behalf of THIS distribution
# (aws:SourceArn)". Nobody else, including another account's distribution, can read the bucket. (The
# older "origin access identity" is replaced by OAC; it needs no key rights for SSE-S3 buckets.)
#
# DETAILS WORTH KNOWING
#   certificate        the wildcard from 05-dns, which MUST be in us-east-1 for CloudFront (it is).
#   viewer protocol    HTTP is redirected to HTTPS; TLS 1.2 is the minimum (policy TLSv1.2_2021).
#   cache policy       AWS's managed "CachingOptimized": 24 h default, compression on.
#   price class 100    edge locations of North America and Europe only: the cheapest class.
#   no WAF here        a CloudFront WAF must be a global web ACL (a second WAF); not worth it for
#                      public pictures at this scale (production attaches one).
#   deleting           a distribution is disabled and then deleted by Terraform; this takes several
#                      minutes, one of the reasons the layer is persistent.
#
# Related files: storage.tf (the bucket), data.tf (zone and certificate), ses.tf (more records in
# the same zone), config.tf (publishes CDN_BASE_URL).

resource "aws_cloudfront_origin_access_control" "images" {
  name                              = "${local.name_prefix}-images"
  description                       = "CloudFront reads the images bucket with signed requests"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  aliases         = ["cdn.${var.domain}"]
  comment         = "${local.name_prefix} event images"

  origin {
    domain_name              = aws_s3_bucket.this["images"].bucket_regional_domain_name
    origin_id                = "images"
    origin_access_control_id = aws_cloudfront_origin_access_control.images.id
  }

  default_cache_behavior {
    target_origin_id       = "images"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.wildcard.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# The read rule on the images bucket (merged with the TLS rule of storage.tf).
data "aws_iam_policy_document" "images" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["images"].json]

  statement {
    sid       = "AllowCloudFrontToReadImages"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["images"].arn}/images/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

# cdn.<domain> -> the distribution. An ALIAS record (a Route 53 feature) is an A record that points
# at an AWS resource by name: it works at any name, costs nothing per query and needs no CNAME.
# Z2FDTNDATAQYW2 is the fixed hosted-zone id that every CloudFront distribution lives in.
resource "aws_route53_record" "cdn" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.this.zone_id
  name    = "cdn.${var.domain}"
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
