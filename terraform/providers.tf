terraform {
  # 1.9 floor: dsx_mode's validation cross-references var.nfs_backend, and
  # cross-variable references in a variable validation block require Terraform 1.9+.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Local state for now. To productionize (and as a talking point in a design
  # review), swap this for an S3 backend + DynamoDB lock table:
  #
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "nfs-harness/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Harness   = "nfs-test"
    }
  }
}
