################################################################################
# Ansible Automation Platform (single node, containerized growth topology)
# on AWS EC2.
#
#   VPC (optional, terraform-aws-modules/vpc)  -->  modules/aap-node
#                                                  EC2 + EIP + SG + IAM +
#                                                  SSM secrets + bootstrap
################################################################################

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(2, length(data.aws_availability_zones.available.names)),
  )

  vpc_id    = var.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  subnet_id = var.create_vpc ? module.vpc[0].public_subnets[0] : var.subnet_id
}

#---------------------------------------------------------------------------
# Network
#---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  count = var.create_vpc ? 1 : 0

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # Public subnets only: one public node, no NAT gateway to pay for.
  public_subnets          = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  map_public_ip_on_launch = true
  enable_nat_gateway      = false

  # The AAP hostname is the EIP public DNS name. Inside the VPC it has to
  # resolve to the private IP, which needs both of these.
  enable_dns_hostnames = true
  enable_dns_support   = true
}

#---------------------------------------------------------------------------
# AAP node
#---------------------------------------------------------------------------
module "aap" {
  source = "./modules/aap-node"

  name      = var.name
  vpc_id    = local.vpc_id
  subnet_id = local.subnet_id

  allowed_cidr_blocks        = var.allowed_cidr_blocks
  instance_type              = var.instance_type
  root_volume_size_gb        = var.root_volume_size_gb
  ami_id                     = var.ami_id
  rhel_major_version         = var.rhel_major_version
  key_name                   = var.key_name
  enable_ssm_session_manager = var.enable_ssm_session_manager

  aap_version           = var.aap_version
  aap_installer_type    = var.aap_installer_type
  aap_installer_s3_uri  = var.aap_installer_s3_uri
  aap_installer_url     = var.aap_installer_url
  aap_hostname          = var.aap_hostname
  route53_zone_id       = var.route53_zone_id
  aap_admin_password    = var.aap_admin_password
  enable_automation_hub = var.enable_automation_hub
  enable_eda            = var.enable_eda
  hub_seed_collections  = var.hub_seed_collections
  extra_inventory_vars  = var.extra_inventory_vars
  wait_for_aap          = var.wait_for_aap
  wait_timeout_minutes  = var.wait_timeout_minutes

  redhat_registry_username            = var.redhat_registry_username
  redhat_registry_password            = var.redhat_registry_password
  redhat_offline_token                = var.redhat_offline_token
  redhat_subscription_allocation_uuid = var.redhat_subscription_allocation_uuid
  aap_manifest_s3_uri                 = var.aap_manifest_s3_uri

  # The VPC (IGW + routes) must be complete before the node boots and starts
  # downloading packages.
  depends_on = [module.vpc]
}
