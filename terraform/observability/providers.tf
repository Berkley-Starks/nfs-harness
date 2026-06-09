###############################################################################
# Observability plane — SEPARATE Terraform root (own state) on purpose.
#
# The whole point of the two-plane split is independent lifecycles: you can
# obs-down without touching the test plane, and `harness down` must never take
# your instruments with it. Separate state is what makes that real — a destroy
# in terraform/ cannot reach anything declared here, and vice versa.
#
# This root stays loosely coupled to the test plane: it reads the test plane's
# outputs (VPC/subnet/SG ids, scrape-target IPs) via terraform_remote_state
# rather than re-declaring or importing them.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Harness   = "nfs-test"
      Plane     = "observability"
    }
  }
}

# Read the test plane's local state for network ids + scrape targets. Loose
# coupling: if the test plane is down, only the scrape target list is empty —
# Prometheus still comes up, it just has nothing to scrape yet.
data "terraform_remote_state" "harness" {
  backend = "local"
  config = {
    path = "${path.module}/../terraform.tfstate"
  }
}
