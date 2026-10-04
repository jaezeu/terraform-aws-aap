output "aap_url" {
  description = "URL of the AAP platform gateway."
  value       = local.aap_url
}

output "aap_hostname" {
  description = "FQDN AAP was installed with."
  value       = local.aap_hostname
}

output "aap_api_urls" {
  description = "Per-component API base URLs through the gateway."
  value = {
    gateway    = "${local.aap_url}/api/gateway/v1/"
    controller = "${local.aap_url}/api/controller/v2/"
    hub        = var.enable_automation_hub ? "${local.aap_url}/api/galaxy/" : null
    eda        = var.enable_eda ? "${local.aap_url}/api/eda/v1/" : null
  }
}

output "aap_admin_username" {
  description = "AAP administrator username."
  value       = local.admin_username
}

output "aap_admin_password" {
  description = "AAP administrator password."
  value       = local.admin_password
  sensitive   = true
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.ec2.id
}

output "public_ip" {
  description = "Elastic IP."
  value       = aws_eip.this.public_ip
}

output "private_ip" {
  description = "Private IP."
  value       = module.ec2.private_ip
}

output "security_group_id" {
  description = "Security group ID."
  value       = module.ec2.security_group_id
}

output "iam_role_name" {
  description = "Instance IAM role name."
  value       = module.ec2.iam_role_name
}

output "ami_id" {
  description = "AMI ID used."
  value       = local.ami_id
}

output "key_name" {
  description = "EC2 key pair name."
  value       = local.key_name
}

output "ssh_private_key" {
  description = "Generated private key (OpenSSH format), or null when key_name was supplied."
  value       = try(tls_private_key.ssh[0].private_key_openssh, null)
  sensitive   = true
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix for this stack."
  value       = local.ssm_prefix
}

output "status_parameter_name" {
  description = "SSM parameter with the install status."
  value       = local.status_parameter
}

output "status_command" {
  description = "AWS CLI command printing the install status."
  value       = "aws ssm get-parameter --region ${local.region} --name ${local.status_parameter} --query Parameter.Value --output text"
}

output "ssh_command" {
  description = "SSH command (ec2-user)."
  value       = "ssh -i <private-key> ec2-user@${aws_eip.this.public_ip}"
}

output "ssm_session_command" {
  description = "Session Manager command, or null when disabled."
  value       = var.enable_ssm_session_manager ? "aws ssm start-session --region ${local.region} --target ${module.ec2.id}" : null
}

output "install_log_command" {
  description = "Follow the bootstrap/installer log."
  value       = "ssh -i <private-key> ec2-user@${aws_eip.this.public_ip} 'sudo tail -f /var/log/aap-install.log'"
}
