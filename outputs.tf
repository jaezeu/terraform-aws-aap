################################################################################
# Outputs for humans and for other workspaces/repos
# (terraform_remote_state / tfe_outputs). Secrets stay sensitive.
################################################################################

output "aap_url" {
  description = "URL of the AAP platform gateway (UI and API entry point)."
  value       = module.aap.aap_url
}

output "aap_hostname" {
  description = "FQDN AAP was installed with (used in its TLS certificate)."
  value       = module.aap.aap_hostname
}

output "aap_api_urls" {
  description = "Per-component API base URLs, all served through the platform gateway."
  value       = module.aap.aap_api_urls
}

output "aap_admin_username" {
  description = "AAP administrator username."
  value       = module.aap.aap_admin_username
}

output "aap_admin_password" {
  description = "AAP administrator password (also stored in SSM Parameter Store)."
  value       = module.aap.aap_admin_password
  sensitive   = true
}

output "aap_status_command" {
  description = "AWS CLI command that prints the install status (pending | installing | ready | failed)."
  value       = module.aap.status_command
}

output "aap_status_parameter_name" {
  description = "SSM parameter holding the install status."
  value       = module.aap.status_parameter_name
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix holding the admin password, DB password, registry credentials, status and URL."
  value       = module.aap.ssm_parameter_prefix
}

output "instance_id" {
  description = "EC2 instance ID of the AAP node."
  value       = module.aap.instance_id
}

output "public_ip" {
  description = "Elastic IP of the AAP node."
  value       = module.aap.public_ip
}

output "private_ip" {
  description = "Private IP of the AAP node."
  value       = module.aap.private_ip
}

output "security_group_id" {
  description = "Security group of the AAP node (add rules here to let other workloads reach it)."
  value       = module.aap.security_group_id
}

output "iam_role_name" {
  description = "IAM role of the AAP node (attach extra policies here, e.g. for the amazon.aws inventory plugin)."
  value       = module.aap.iam_role_name
}

output "vpc_id" {
  description = "VPC the node runs in."
  value       = local.vpc_id
}

output "subnet_id" {
  description = "Subnet the node runs in."
  value       = local.subnet_id
}

output "ami_id" {
  description = "AMI used for the node."
  value       = module.aap.ami_id
}

output "key_name" {
  description = "EC2 key pair name used for the node."
  value       = module.aap.key_name
}

output "ssh_private_key" {
  description = "Generated SSH private key (OpenSSH format) when key_name was not provided, otherwise null."
  value       = module.aap.ssh_private_key
  sensitive   = true
}

output "ssh_command" {
  description = "SSH command for the node."
  value       = module.aap.ssh_command
}

output "ssm_session_command" {
  description = "Session Manager command for the node (null when enable_ssm_session_manager = false)."
  value       = module.aap.ssm_session_command
}

output "install_log_command" {
  description = "Follow the bootstrap/installer log on the node."
  value       = module.aap.install_log_command
}
