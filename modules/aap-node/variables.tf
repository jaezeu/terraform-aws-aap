variable "name" {
  description = "Name prefix for resources, tags and the SSM parameter path (/aap/<name>/...)."
  type        = string
}

variable "tags" {
  description = "Extra tags for the resources created by this module."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC to create the security group in."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet (route to an Internet Gateway) for the node."
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach 443/80 (AAP) and 22 (SSH)."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type (minimum 4 vCPU / 16 GiB)."
  type        = string
  default     = "m6i.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root volume size in GiB (minimum 60)."
  type        = number
  default     = 100
}

variable "ami_id" {
  description = "AMI override. Defaults to the latest Red Hat RHEL <rhel_major_version> AMI."
  type        = string
  default     = null
}

variable "rhel_major_version" {
  description = "RHEL major version used for the AMI lookup (9 or 10)."
  type        = string
  default     = "9"
}

variable "key_name" {
  description = "Existing EC2 key pair name. A key pair is generated when null."
  type        = string
  default     = null
}

variable "enable_ssm_session_manager" {
  description = "Install the SSM Agent and attach AmazonSSMManagedInstanceCore."
  type        = bool
  default     = true
}

variable "aap_version" {
  description = "AAP release stream, e.g. 2.6."
  type        = string
  default     = "2.6"
}

variable "aap_installer_type" {
  description = "setup (online) or setup-bundle (offline bundle)."
  type        = string
  default     = "setup"
}

variable "aap_installer_s3_uri" {
  description = "s3:// URI of a pre-downloaded setup tarball."
  type        = string
  default     = null
}

variable "aap_installer_url" {
  description = "HTTPS URL of a setup tarball."
  type        = string
  default     = null
  sensitive   = true
}

variable "aap_hostname" {
  description = "FQDN for AAP. Defaults to the Elastic IP public DNS name."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Hosted zone for an A record of aap_hostname."
  type        = string
  default     = null
}

variable "aap_admin_password" {
  description = "AAP admin password. Generated when null."
  type        = string
  default     = null
  sensitive   = true
}

variable "enable_automation_hub" {
  description = "Install private automation hub."
  type        = bool
  default     = true
}

variable "enable_eda" {
  description = "Install Event-Driven Ansible controller."
  type        = bool
  default     = true
}

variable "hub_seed_collections" {
  description = "Seed automation hub with the bundled Red Hat collections."
  type        = bool
  default     = false
}

variable "extra_inventory_vars" {
  description = "Additional key=value pairs appended to [all:vars]."
  type        = map(string)
  default     = {}
}

variable "wait_for_aap" {
  description = "Block the apply until the AAP API answers."
  type        = bool
  default     = true
}

variable "wait_timeout_minutes" {
  description = "Timeout for wait_for_aap."
  type        = number
  default     = 60
}

variable "redhat_registry_username" {
  description = "registry.redhat.io username / service account."
  type        = string
  sensitive   = true
}

variable "redhat_registry_password" {
  description = "registry.redhat.io password / token."
  type        = string
  sensitive   = true
}

variable "redhat_offline_token" {
  description = "Red Hat API offline token."
  type        = string
  default     = null
  sensitive   = true
}

variable "redhat_subscription_allocation_uuid" {
  description = "Subscription allocation UUID to export a manifest from."
  type        = string
  default     = null
}

variable "aap_manifest_s3_uri" {
  description = "s3:// URI of a subscription manifest zip."
  type        = string
  default     = null
}
