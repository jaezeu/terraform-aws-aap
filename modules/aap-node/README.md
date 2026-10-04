# aap-node

One RHEL EC2 instance that installs containerized Ansible Automation Platform (growth topology) at first boot, plus the Elastic IP, security group, instance role, SSM Parameter Store secrets and an optional readiness gate.

The root of this repository wraps it with a VPC. To embed the node in your own network instead:

```hcl
module "aap" {
  source = "github.com/<you>/<repo>//modules/aap-node?ref=main"

  name                = "aap-demo"
  vpc_id              = "vpc-0123456789abcdef0"
  subnet_id           = "subnet-0123456789abcdef0" # public subnet
  allowed_cidr_blocks = ["203.0.113.0/24"]

  redhat_registry_username = var.redhat_registry_username
  redhat_registry_password = var.redhat_registry_password
  redhat_offline_token     = var.redhat_offline_token
}
```

Requirements: the subnet must route to an Internet Gateway and the VPC must have DNS hostnames enabled. The AAP hostname is the Elastic IP public DNS name, which has to resolve to the private IP from inside the VPC.

| File | Purpose |
|---|---|
| `main.tf` | AMI lookup, key pair, passwords, SSM parameters, EIP, IAM policy, EC2 module, readiness gate |
| `templates/inventory.ini.tftpl` | Installer inventory skeleton (secrets substituted on the node) |
| `scripts/install_aap.sh` | Static first-boot bootstrap run by cloud-init |
| `scripts/wait_for_aap.sh` | Readiness poll used by the `local-exec` provisioner |

Inputs, outputs and the bootstrap flow are documented in the [root README](../../README.md).
