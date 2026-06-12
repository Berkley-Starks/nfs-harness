###############################################################################
# SSM access for the private fleet (private_networking only).
#
# With no public IPs and no SSH, both human access and Ansible go through AWS
# Systems Manager. Each fleet instance needs the SSM agent (preinstalled on
# AL2023) plus an instance profile granting AmazonSSMManagedInstanceCore so the
# agent can register. Ansible's aws_ssm connection plugin stages modules through
# an S3 bucket, so the instances also get scoped read/write to a dedicated,
# fully-private bucket. All of this is gated on private_networking, so the cheap
# public default provisions none of it.
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ssm" {
  count = var.private_networking ? 1 : 0
  name  = "${var.project_name}-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-ssm-role" }
}

# AWS-managed policy: the minimum for the SSM agent to register and run sessions.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = var.private_networking ? 1 : 0
  role       = aws_iam_role.ssm[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Transfer bucket for the Ansible aws_ssm connection plugin. Locked down: no
# public access, encrypted, force_destroy so `down` can clean it up.
resource "aws_s3_bucket" "ssm" {
  count         = var.private_networking ? 1 : 0
  bucket        = "${var.project_name}-ssm-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.project_name}-ssm-transfer" }
}

resource "aws_s3_bucket_public_access_block" "ssm" {
  count                   = var.private_networking ? 1 : 0
  bucket                  = aws_s3_bucket.ssm[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm" {
  count  = var.private_networking ? 1 : 0
  bucket = aws_s3_bucket.ssm[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Instance-side access to the transfer bucket (scoped to this bucket only).
resource "aws_iam_role_policy" "ssm_s3" {
  count = var.private_networking ? 1 : 0
  name  = "${var.project_name}-ssm-s3"
  role  = aws_iam_role.ssm[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:GetEncryptionConfiguration",
      ]
      Resource = [
        aws_s3_bucket.ssm[0].arn,
        "${aws_s3_bucket.ssm[0].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ssm" {
  count = var.private_networking ? 1 : 0
  name  = "${var.project_name}-ssm"
  role  = aws_iam_role.ssm[0].name
}

locals {
  # Attached to every fleet instance in private mode; null (none) otherwise.
  fleet_instance_profile = var.private_networking ? aws_iam_instance_profile.ssm[0].name : null
}
