terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in Cloudflare R2 (S3-compatible). Endpoint and credentials are
  # injected at init time via -backend-config (see `just ops tofu-kms`).
  backend "s3" {
    bucket         = "homelab-tfstate"
    key            = "aws-kms/terraform.tfstate"
    region         = "auto"
    use_lockfile   = true
    use_path_style = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "home-lab"
      ManagedBy = "opentofu"
    }
  }
}
