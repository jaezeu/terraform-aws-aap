################################################################################
# aap-node: one RHEL EC2 instance running containerized AAP (growth topology)
#
# Boot sequence (scripts/install_aap.sh):
#   cloud-init writes install.env + inventory template + script
#   -> secrets from SSM Parameter Store
#   -> installer tarball (S3 | URL | Red Hat Customer Portal API)
#   -> optional subscription manifest
#   -> ansible-playbook ansible.containerized_installer.install
#   -> status = ready (SSM parameter + instance tag)
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# Latest official Red Hat RHEL AMI. These pay-as-you-go images are backed by
# Red Hat Update Infrastructure, so `dnf` works without subscription-manager.
# 309956199498 is the Red Hat AWS account.
data "aws_ami" "rhel" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-${var.rhel_major_version}.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  ami_id         = var.ami_id != null ? var.ami_id : data.aws_ami.rhel[0].id
  key_name       = var.key_name != null ? var.key_name : aws_key_pair.this[0].key_name
  admin_username = "admin"
  admin_password = var.aap_admin_password != null ? var.aap_admin_password : random_password.admin.result

  # AAP bakes its hostname into TLS certificates and service URLs, so it must
  # be stable across stop/start: allocate the EIP first and derive it.
  aap_hostname = var.aap_hostname != null ? var.aap_hostname : aws_eip.this.public_dns
  aap_url      = "https://${local.aap_hostname}"

  ssm_prefix       = "/aap/${var.name}"
  status_parameter = "${local.ssm_prefix}/status"
  install_user     = "aap"
  workdir          = "/opt/aap"

  # Secrets reach the node through SSM Parameter Store (SecureString), never
  # through user data. The key set is static because for_each cannot depend
  # on sensitive values; an absent offline token is stored as "unset".
  secret_names = ["admin_password", "pg_password", "registry_username", "registry_password", "redhat_offline_token"]
  secrets = {
    admin_password       = local.admin_password
    pg_password          = random_password.postgres.result
    registry_username    = var.redhat_registry_username
    registry_password    = var.redhat_registry_password
    redhat_offline_token = var.redhat_offline_token != null ? var.redhat_offline_token : "unset"
  }

  s3_object_arns = [
    for uri in [var.aap_installer_s3_uri, var.aap_manifest_s3_uri] :
    "arn:${local.partition}:s3:::${trimprefix(uri, "s3://")}" if uri != null
  ]

  ingress_ports = {
    https = { port = 443, description = "AAP platform gateway (HTTPS)" }
    http  = { port = 80, description = "AAP platform gateway (HTTP redirect)" }
    ssh   = { port = 22, description = "SSH" }
  }

  ingress_rules = {
    for pair in setproduct(keys(local.ingress_ports), var.allowed_cidr_blocks) :
    "${pair[0]}-${replace(replace(pair[1], ".", "-"), "/", "_")}" => {
      description = local.ingress_ports[pair[0]].description
      from_port   = local.ingress_ports[pair[0]].port
      to_port     = local.ingress_ports[pair[0]].port
      ip_protocol = "tcp"
      cidr_ipv4   = pair[1]
    }
  }

  #---------------------------------------------------------------------------
  # Bootstrap payload (cloud-config). Settings only, no secrets.
  #---------------------------------------------------------------------------
  install_env = {
    AAP_HOSTNAME         = local.aap_hostname
    AAP_URL              = local.aap_url
    EXPECTED_PUBLIC_IP   = aws_eip.this.public_ip
    AWS_REGION           = local.region
    SSM_PREFIX           = local.ssm_prefix
    STATUS_PARAM         = local.status_parameter
    AAP_VERSION          = var.aap_version
    AAP_INSTALLER_TYPE   = var.aap_installer_type
    INSTALLER_S3_URI     = var.aap_installer_s3_uri != null ? var.aap_installer_s3_uri : ""
    INSTALLER_URL        = var.aap_installer_url != null ? var.aap_installer_url : ""
    MANIFEST_S3_URI      = var.aap_manifest_s3_uri != null ? var.aap_manifest_s3_uri : ""
    RHSM_ALLOCATION_UUID = var.redhat_subscription_allocation_uuid != null ? var.redhat_subscription_allocation_uuid : ""
    INSTALL_SSM_AGENT    = tostring(var.enable_ssm_session_manager)
    INSTALL_USER         = local.install_user
    WORKDIR              = local.workdir
  }

  install_env_file = join("\n", concat(
    ["# Rendered by Terraform - consumed by install_aap.sh"],
    [for k in sort(keys(local.install_env)) : "${k}='${replace(local.install_env[k], "'", "'\\''")}'"],
    [""],
  ))

  inventory_template = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    aap_version          = var.aap_version
    hostname             = local.aap_hostname
    enable_hub           = var.enable_automation_hub
    enable_eda           = var.enable_eda
    hub_seed_collections = var.hub_seed_collections
    bundle_install       = var.aap_installer_type == "setup-bundle"
    extra_vars           = var.extra_inventory_vars
  })

  cloud_config = join("\n", ["#cloud-config", yamlencode({
    # The installer needs the hostname we set; stop cloud-init from resetting it.
    preserve_hostname = true
    write_files = [
      {
        path        = "${local.workdir}/install.env"
        owner       = "root:root"
        permissions = "0600"
        content     = local.install_env_file
      },
      {
        path        = "${local.workdir}/inventory.tmpl"
        owner       = "root:root"
        permissions = "0600"
        content     = local.inventory_template
      },
      {
        path        = "${local.workdir}/install_aap.sh"
        owner       = "root:root"
        permissions = "0750"
        content     = file("${path.module}/scripts/install_aap.sh")
      },
    ]
    runcmd = [["/bin/bash", "${local.workdir}/install_aap.sh"]]
  })])
}

#---------------------------------------------------------------------------
# Credentials
#---------------------------------------------------------------------------
resource "tls_private_key" "ssh" {
  count = var.key_name == null ? 1 : 0

  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  count = var.key_name == null ? 1 : 0

  key_name   = var.name
  public_key = tls_private_key.ssh[0].public_key_openssh
}

# Always generated (count cannot depend on the sensitive aap_admin_password);
# only used when no password was supplied.
resource "random_password" "admin" {
  length      = 20
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "secret" {
  for_each = toset(local.secret_names)

  name        = "${local.ssm_prefix}/${each.key}"
  description = "AAP bootstrap secret for ${var.name} (read by the instance role at first boot)"
  type        = "SecureString"
  tier        = "Intelligent-Tiering"
  value       = local.secrets[each.key]
}

# Updated by the node as it progresses: pending -> installing -> ready | failed
resource "aws_ssm_parameter" "status" {
  name        = local.status_parameter
  description = "AAP install status for ${var.name}"
  type        = "String"
  value       = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "url" {
  name        = "${local.ssm_prefix}/url"
  description = "AAP platform gateway URL for ${var.name}"
  type        = "String"
  value       = local.aap_url
}

#---------------------------------------------------------------------------
# Network identity
#---------------------------------------------------------------------------
resource "aws_eip" "this" {
  domain = "vpc"

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = module.ec2.id
}

resource "aws_route53_record" "this" {
  count = var.route53_zone_id != null ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.aap_hostname
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}

#---------------------------------------------------------------------------
# Instance permissions
#---------------------------------------------------------------------------
data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ReadAapSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_prefix}/*"]
  }

  statement {
    sid       = "PublishAapStatus"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.status_parameter}"]
  }

  # Lets the node tag itself with aap:status=<state>, limited to instances
  # that carry this stack's tag.
  statement {
    sid       = "TagSelf"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/aap:stack"
      values   = [var.name]
    }
  }

  dynamic "statement" {
    for_each = length(local.s3_object_arns) > 0 ? [1] : []

    content {
      sid       = "ReadInstallerArtifacts"
      actions   = ["s3:GetObject"]
      resources = local.s3_object_arns
    }
  }
}

resource "aws_iam_policy" "instance" {
  name_prefix = "${var.name}-"
  description = "AAP node (${var.name}): read bootstrap secrets, publish status"
  policy      = data.aws_iam_policy_document.instance.json
}

#---------------------------------------------------------------------------
# EC2 instance (security group + instance profile come from the module)
#---------------------------------------------------------------------------
module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.4"

  name          = var.name
  ami           = local.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = local.key_name

  # A public IP at launch so packages can be fetched before the EIP lands.
  associate_public_ip_address = true

  create_security_group        = true
  security_group_name          = var.name
  security_group_description   = "Ansible Automation Platform node (${var.name})"
  security_group_vpc_id        = var.vpc_id
  security_group_ingress_rules = local.ingress_rules

  create_iam_instance_profile = true
  iam_role_name               = var.name
  iam_role_description        = "Instance role for the AAP node ${var.name}"
  iam_role_policies = merge(
    { aap_bootstrap = aws_iam_policy.instance.arn },
    var.enable_ssm_session_manager ? { ssm_core = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore" } : {},
  )

  # IMDSv2 only. Hop limit 2 so execution-environment containers can also use
  # the instance role (e.g. the amazon.aws inventory plugin).
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device = {
    size                  = var.root_volume_size_gb
    type                  = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  ebs_optimized = true

  user_data_base64            = base64gzip(local.cloud_config)
  user_data_replace_on_change = true

  tags = merge(var.tags, { "aap:stack" = var.name })
}

#---------------------------------------------------------------------------
# Optional: hold the apply until the API answers through the gateway
#---------------------------------------------------------------------------
resource "terraform_data" "wait_for_aap" {
  count = var.wait_for_aap ? 1 : 0

  triggers_replace = [module.ec2.id]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash \"${path.module}/scripts/wait_for_aap.sh\""

    environment = {
      AAP_URL         = local.aap_url
      AAP_USERNAME    = local.admin_username
      AAP_PASSWORD    = local.admin_password
      TIMEOUT_MINUTES = tostring(var.wait_timeout_minutes)
    }
  }

  depends_on = [
    aws_eip_association.this,
    aws_route53_record.this,
    aws_ssm_parameter.secret,
  ]
}
