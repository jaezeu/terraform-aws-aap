################################################################################
# Example: a *separate* HCP Terraform / TFE workspace (or repo) that consumes
# the AAP created by this repository.
#
#   1. The AAP workspace applies this repo and exposes aap_url / credentials
#      as outputs (secrets stay sensitive).
#   2. This workspace reads them with the tfe_outputs data source and talks to
#      AAP through the ansible/aap provider. Add a run trigger from the AAP
#      workspace to this one and it re-plans automatically after each rebuild.
#
# Set TFE_TOKEN (or use the tfe provider's hostname/token arguments) and the
# two variables below.
################################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.81"
    }
    aap = {
      source  = "ansible/aap"
      version = "~> 1.5"
    }
  }
}

variable "tfe_organization" {
  description = "HCP Terraform / TFE organization that owns the AAP workspace."
  type        = string
}

variable "aap_workspace" {
  description = "Name of the workspace that applied this repository."
  type        = string
  default     = "aap-on-aws"
}

data "tfe_outputs" "aap" {
  organization = var.tfe_organization
  workspace    = var.aap_workspace
}

provider "aap" {
  host                 = data.tfe_outputs.aap.values.aap_url
  username             = data.tfe_outputs.aap.values.aap_admin_username
  password             = data.tfe_outputs.aap.values.aap_admin_password
  insecure_skip_verify = true # the installer issues a self-signed certificate
}

# Smoke test: an inventory and a host created through the platform gateway.
resource "aap_inventory" "demo" {
  name        = "terraform-demo"
  description = "Created by Terraform via the ansible/aap provider"
}

resource "aap_host" "demo" {
  inventory_id = aap_inventory.demo.id
  name         = "demo-host-1"
  variables = jsonencode({
    ansible_host = "10.80.1.10"
  })
}

output "aap_url" {
  value = data.tfe_outputs.aap.values.aap_url
}
