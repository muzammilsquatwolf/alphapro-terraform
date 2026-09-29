terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # DELIBERATELY NO BACKEND BLOCK.
  #
  # This root creates the S3 buckets and DynamoDB lock table that the dev and
  # prod roots use as their remote backend. Terraform cannot store its state in
  # a bucket that doesn't exist yet, so this one root keeps LOCAL state — that's
  # the whole point of splitting it out.
  #
  # Its state file is small and rarely changes. It is git-ignored (*.tfstate),
  # so if you lose it, don't re-apply — `terraform import` the three resources
  # back instead, or you'll get "already exists" errors. Every resource here
  # also carries prevent_destroy, so a stray destroy can't orphan your real
  # state files.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "alphapro"
      Purpose   = "terraform-backend"
      ManagedBy = "terraform"
    }
  }
}
