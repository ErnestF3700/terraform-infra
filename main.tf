terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
provider "aws" {
  region = "us-east-1"
}

# --- 1. Nowy bucket ---
resource "aws_s3_bucket" "new_bucket" {
  bucket = "task-webiste-erni-copy123"
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.new_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.new_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# resource "aws_s3_bucket_policy" "public_read" {
#   bucket = aws_s3_bucket.new_bucket.id
#   policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [{
#       Effect    = "Allow",
#       Principal = "*",
#       Action    = "s3:GetObject",
#       Resource  = "${aws_s3_bucket.new_bucket.arn}/*"
#       },
#       {
#         Sid       = "PublicListBucket",
#         Effect    = "Allow",
#         Principal = "*",
#         Action    = "s3:ListBucket",
#         Resource  = aws_s3_bucket.new_bucket.arn
#     }]
#   })
# }

# --- 2. Skopiowanie plików ze starego bucketa ---
# Ten blok wymaga AWS CLI z odpowiednimi uprawnieniami
resource "null_resource" "copy_s3_objects" {
  provisioner "local-exec" {
    command = "aws s3 sync s3://task-webiste-erni s3://${aws_s3_bucket.new_bucket.bucket}"
  }
}

# --- 3. CloudFront pointing to new bucket ---
resource "aws_cloudfront_distribution" "cdn" {
  depends_on = [
    null_resource.copy_s3_objects,
    aws_wafv2_web_acl.rate_limit_acl
  ]

  origin {
    domain_name = aws_s3_bucket_website_configuration.website.website_endpoint
    origin_id   = "s3-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }
  # 👇 DODANE
  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    prefix          = "cloudfront/"
  }
  web_acl_id = aws_wafv2_web_acl.rate_limit_acl.arn
  # 👇 DODANE
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/4xx.html"
  }
  custom_error_response {
    error_code         = 500
    response_code      = 200
    response_page_path = "/5xx.html"
  }
  # 👇 DODANE


  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# --- 4. Output z nowym CloudFront URL ---
output "cloudfront_url" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

# CloudFront OAI (dostęp do S3)
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI for CloudFront to access S3"
}

# Bucket do logów
resource "aws_s3_bucket" "logs" {
  bucket = "my-website-stage-task90912-logs"

  lifecycle_rule {
    id      = "expire-logs"
    enabled = true

    expiration {
      days = 30
    }
  }
}

# WAF – limit 100 req/min/IP
resource "aws_wafv2_web_acl" "rate_limit_acl" {
  name        = "cf-rate-limit-acl123"
  description = "Limit to 100 req/min per IP"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cfWAF"
    sampled_requests_enabled   = true
  }
}
resource "aws_cloudwatch_dashboard" "cf_dashboard" {
  dashboard_name = "CloudFront-Monitoring"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric",
        width  = 24,
        height = 8,
        properties = {
          title   = "CloudFront & WAF Metrics",
          region  = "us-east-1",
          view    = "timeSeries",
          stacked = false,
          metrics = [
            ["AWS/CloudFront", "4xxErrorRate", "DistributionId", aws_cloudfront_distribution.cdn.id],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", aws_cloudfront_distribution.cdn.id],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.rate_limit_acl.name]
          ],
          period = 60,
          stat   = "Average"
        }
      }
    ]
  })
}
