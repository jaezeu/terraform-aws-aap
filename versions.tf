terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6, < 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }

  # ---------------------------------------------------------------------------
  # HCP Terraform / Terraform Enterprise
  # Either uncomment this block, or leave it commented and export
  # TF_CLOUD_ORGANIZATION / TF_WORKSPACE (and TF_CLOUD_HOSTNAME for TFE) before
  # `terraform init`. See README "Running in HCP Terraform / TFE".
  # ---------------------------------------------------------------------------
  # cloud {
  #   organization = "my-org"
  #   # hostname   = "tfe.example.com"   # Terraform Enterprise only
  #   workspaces {
  #     name = "aap-on-aws"
  #   }
  # }
}
