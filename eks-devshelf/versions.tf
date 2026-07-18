terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local backend for now. Uncomment below once ready to move state to S3 —
  # local state is fine solo, but has no locking and lives only on this
  # machine, so it's a real risk if this laptop is lost or wiped.
  #
  # backend "s3" {
  #   bucket         = "devshelf-terraform-state"
  #   key            = "eks/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "devshelf-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
