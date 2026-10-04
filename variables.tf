################################################################################
# General
################################################################################

variable "name" {
  description = "Name prefix for every resource. Also used in tags and as the SSM Parameter Store path (/aap/<name>/...)."
  type        = string
  default     = "aap-demo"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 characters of lowercase letters, digits and hyphens."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "tags" {
  description = "Extra tags applied to every resource (through the provider default_tags)."
  type        = map(string)
  default     = {}
}

################################################################################
# Networking
################################################################################

variable "create_vpc" {
  description = "Create a dedicated VPC with public subnets (terraform-aws-modules/vpc). Set to false to deploy into an existing VPC using vpc_id and subnet_id."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC created when create_vpc = true."
  type        = string
  default     = "10.80.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "vpc_id" {
  description = "Existing VPC ID (only when create_vpc = false). The VPC must have DNS support and DNS hostnames enabled."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Existing public subnet ID with a route to an Internet Gateway (only when create_vpc = false)."
  type        = string
  default     = null

  validation {
    condition     = var.create_vpc || (var.vpc_id != null && var.subnet_id != null)
    error_message = "When create_vpc = false you must set both vpc_id and subnet_id."
  }
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach AAP (443/80) and SSH (22). The default is wide open, which is only acceptable for a short-lived demo; restrict it to your IP(s) otherwise."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_cidr_blocks) > 0 && alltrue([for c in var.allowed_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "allowed_cidr_blocks must contain at least one valid IPv4 CIDR block."
  }
}

################################################################################
# Compute
################################################################################

variable "instance_type" {
  description = "EC2 instance type. Red Hat requires at least 4 vCPU / 16 GiB for the containerized growth topology; 8 vCPU / 32 GiB is comfortable with automation hub and EDA enabled."
  type        = string
  default     = "m6i.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (gp3, encrypted). Red Hat requires at least 60 GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gb >= 60
    error_message = "root_volume_size_gb must be at least 60."
  }
}

variable "ami_id" {
  description = "AMI override. When null, the latest official Red Hat RHEL <rhel_major_version> x86_64 AMI (owner 309956199498) is used."
  type        = string
  default     = null
}

variable "rhel_major_version" {
  description = "RHEL major version for the AMI lookup when ami_id is null. AAP 2.6 supports RHEL 9 and 10."
  type        = string
  default     = "9"

  validation {
    condition     = contains(["9", "10"], var.rhel_major_version)
    error_message = "rhel_major_version must be \"9\" or \"10\"."
  }
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH as ec2-user. When null a key pair is generated and the private key is exposed as a sensitive output."
  type        = string
  default     = null
}

variable "enable_ssm_session_manager" {
  description = "Install the SSM Agent and attach AmazonSSMManagedInstanceCore so a shell can be opened with `aws ssm start-session` (no SSH key or open port needed)."
  type        = bool
  default     = true
}

################################################################################
# Ansible Automation Platform
################################################################################

variable "aap_version" {
  description = "AAP release stream to install. Used to find the latest containerized setup tarball on the Red Hat Customer Portal."
  type        = string
  default     = "2.6"

  validation {
    condition     = can(regex("^2\\.[0-9]+$", var.aap_version))
    error_message = "aap_version must look like \"2.6\"."
  }
}

variable "aap_installer_type" {
  description = "\"setup\" = online installer (small download, pulls the container images from registry.redhat.io). \"setup-bundle\" = offline bundle with the images included (multi-GB download)."
  type        = string
  default     = "setup"

  validation {
    condition     = contains(["setup", "setup-bundle"], var.aap_installer_type)
    error_message = "aap_installer_type must be \"setup\" or \"setup-bundle\"."
  }
}

variable "aap_installer_s3_uri" {
  description = "Optional s3://bucket/key of a pre-downloaded containerized setup tarball. Takes precedence over aap_installer_url and the Red Hat API download. The instance role is granted s3:GetObject on it."
  type        = string
  default     = null

  validation {
    condition     = var.aap_installer_s3_uri == null || startswith(coalesce(var.aap_installer_s3_uri, "s3://"), "s3://")
    error_message = "aap_installer_s3_uri must start with s3://."
  }
}

variable "aap_installer_url" {
  description = "Optional HTTPS URL (for example a pre-signed URL or an internal artifact server) of the containerized setup tarball. Used when aap_installer_s3_uri is not set."
  type        = string
  default     = null
  sensitive   = true
}

variable "aap_hostname" {
  description = "FQDN to install AAP under. Defaults to the Elastic IP public DNS name (ec2-x-x-x-x.<region>.compute.amazonaws.com). Set it together with route53_zone_id for a friendly name."
  type        = string
  default     = null

  validation {
    condition     = var.aap_hostname == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", coalesce(var.aap_hostname, "a.b")))
    error_message = "aap_hostname must be a lowercase fully qualified domain name."
  }
}

variable "route53_zone_id" {
  description = "Optional Route 53 hosted zone ID. When set, an A record for aap_hostname pointing at the Elastic IP is created."
  type        = string
  default     = null

  validation {
    condition     = var.route53_zone_id == null || var.aap_hostname != null
    error_message = "route53_zone_id requires aap_hostname."
  }
}

variable "aap_admin_password" {
  description = "Password for the AAP `admin` user (gateway, controller, hub and EDA share it). Generated when null. Must not contain double quotes or backslashes."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.aap_admin_password == null || (length(coalesce(var.aap_admin_password, "x")) >= 8 && !can(regex("[\"\\\\]", coalesce(var.aap_admin_password, "x"))))
    error_message = "aap_admin_password must be at least 8 characters and must not contain double quotes or backslashes."
  }
}

variable "enable_automation_hub" {
  description = "Install private automation hub on the node."
  type        = bool
  default     = true
}

variable "enable_eda" {
  description = "Install Event-Driven Ansible controller on the node."
  type        = bool
  default     = true
}

variable "hub_seed_collections" {
  description = "Seed automation hub with the Red Hat certified/validated collections shipped with the installer. Adds a lot of install time; off by default."
  type        = bool
  default     = false
}

variable "extra_inventory_vars" {
  description = "Additional key=value pairs appended to [all:vars] of the installer inventory (for example the postinstall configuration-as-code variables)."
  type        = map(string)
  default     = {}
}

variable "wait_for_aap" {
  description = "Block `terraform apply` until the AAP API answers through the platform gateway. Implemented with local-exec (bash + curl), which works on HCP Terraform and TFE agents. Disable for a fire-and-forget apply."
  type        = bool
  default     = true
}

variable "wait_timeout_minutes" {
  description = "How long wait_for_aap polls before failing the apply."
  type        = number
  default     = 60
}

################################################################################
# Red Hat credentials (README: Prerequisites)
################################################################################

variable "redhat_registry_username" {
  description = "registry.redhat.io username: a registry service account (\"12345678|name\") or your Red Hat login. The installer uses it to pull the AAP container images."
  type        = string
  sensitive   = true
}

variable "redhat_registry_password" {
  description = "registry.redhat.io password or registry service-account token."
  type        = string
  sensitive   = true
}

variable "redhat_offline_token" {
  description = "Red Hat API offline token from https://access.redhat.com/management/api. Used to download the latest installer and, optionally, to export a subscription manifest. Required unless aap_installer_s3_uri or aap_installer_url is set."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.redhat_offline_token != null || var.aap_installer_s3_uri != null || var.aap_installer_url != null
    error_message = "Set redhat_offline_token, or provide the installer tarball through aap_installer_s3_uri / aap_installer_url."
  }
}

variable "redhat_subscription_allocation_uuid" {
  description = "Optional UUID of a subscription allocation (https://access.redhat.com/management/subscription_allocations). When set, the manifest is exported through the Red Hat API and applied during the install so AAP comes up licensed. Requires redhat_offline_token."
  type        = string
  default     = null

  validation {
    condition     = var.redhat_subscription_allocation_uuid == null || var.redhat_offline_token != null
    error_message = "redhat_subscription_allocation_uuid requires redhat_offline_token."
  }
}

variable "aap_manifest_s3_uri" {
  description = "Optional s3://bucket/key of a subscription manifest zip to apply during the install (alternative to redhat_subscription_allocation_uuid)."
  type        = string
  default     = null

  validation {
    condition     = var.aap_manifest_s3_uri == null || startswith(coalesce(var.aap_manifest_s3_uri, "s3://"), "s3://")
    error_message = "aap_manifest_s3_uri must start with s3://."
  }
}
