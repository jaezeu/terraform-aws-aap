# Ansible Automation Platform on AWS EC2 (Terraform)

Spin up a complete, single-node **Red Hat Ansible Automation Platform (AAP) 2.6** on AWS with one `terraform apply`, then point other repositories, HCP Terraform workspaces or TFE at it.

The node runs the official **containerized installer** in the Red Hat *growth topology* (platform gateway, automation controller, private automation hub, Event-Driven Ansible, PostgreSQL and Redis on one RHEL host). Everything is driven by Terraform: the VPC, the instance, the Red Hat downloads, the subscription manifest and the readiness check.

```
                       terraform apply
                              |
   +--------------------------v---------------------------+
   |  VPC (terraform-aws-modules/vpc, optional)           |
   |                                                      |
   |   public subnet                                      |
   |   +----------------------------------------------+   |
   |   | EC2 RHEL 9 (m6i.2xlarge, 100 GiB gp3)        |   |
   |   |  cloud-init -> install_aap.sh                |   |
   |   |   1. secrets  <- SSM Parameter Store         |   |
   |   |   2. installer <- Red Hat API | S3 | URL     |   |
   |   |   3. manifest  <- RHSM API | S3 (optional)   |   |
   |   |   4. ansible.containerized_installer.install |   |
   |   |   5. status -> SSM + instance tag            |   |
   |   +----------------------+-----------------------+   |
   |                          | Elastic IP (stable hostname)
   +--------------------------+---------------------------+
                              |
        https://ec2-x-x-x-x.<region>.compute.amazonaws.com
        (gateway UI/API; controller, hub and EDA APIs behind it)
```

## Why this repository exists

* [terraform-actions-ansible-job-vault-ssh-vm-config](https://github.com/jaezeu/terraform-actions-ansible-job-vault-ssh-vm-config) **does not create AAP**. It uses the `ansible/aap` provider to launch job templates on an AAP that must already exist (controller host, username and password are inputs).
* [hashicorp-redhat-apj/demo-packer-aap](https://github.com/hashicorp-redhat-apj/demo-packer-aap) bakes AAP 2.5 into an AMI with Packer. It depends on a HashiCorp-internal base AMI, ships a pinned installer tarball in git and installs under a fixed hostname (`aap.demo.local`), so it is not a drop-in way to get a working AAP endpoint.

This repo fills the gap: a self-contained Terraform project whose outputs (URL, admin credentials, security group, instance role) are what downstream automation needs. It is written to run locally, in **HCP Terraform** and in **Terraform Enterprise**.

## What gets created

| Component | Details |
|---|---|
| VPC | `terraform-aws-modules/vpc/aws` v6: 2 public subnets, IGW, DNS hostnames on, no NAT gateway. Skip with `create_vpc = false`. |
| EC2 instance | `terraform-aws-modules/ec2-instance/aws` v6: latest Red Hat RHEL 9 (or 10) AMI, IMDSv2 only, encrypted gp3 root, security group (443/80/22 from `allowed_cidr_blocks`), instance profile. |
| Elastic IP | Allocated before the instance so the AAP hostname (`ec2-…compute.amazonaws.com`) is known at install time and survives stop/start. Optional Route 53 record. |
| SSM Parameter Store | `/aap/<name>/…` SecureString secrets (admin password, DB password, registry credentials, offline token), plus `status` and `url`. |
| IAM | Instance role: read those parameters, write `status`, tag itself, `s3:GetObject` on any installer/manifest objects you point at, `AmazonSSMManagedInstanceCore` for Session Manager. |
| Key pair | Generated ED25519 key (sensitive output) unless `key_name` is given. |
| Readiness gate | `terraform_data` + `local-exec` that polls `/api/controller/v2/ping/` through the gateway until it returns 200 (`wait_for_aap`). |

Nothing is installed from HashiCorp- or Red Hat-internal locations. The AMI is the public pay-as-you-go RHEL image (RHUI-backed, no `subscription-manager` needed) and the installer is fetched from the Red Hat Customer Portal with your own offline token.

## Prerequisites

### Tooling

* Terraform >= 1.9 (HCP Terraform / TFE workers are fine).
* AWS credentials with rights to create VPC, EC2, IAM roles/policies, SSM parameters and (optionally) Route 53 records.
* `bash` and `curl` on the machine running `terraform apply` for the readiness gate. WSL, macOS, Linux and HCP Terraform workers all have them. Set `wait_for_aap = false` to drop this requirement.

### Red Hat account items

You need a Red Hat account with an AAP subscription (a 60-day trial or the Red Hat Partner Connect demo subscription both work).

| Variable | Where to get it |
|---|---|
| `redhat_registry_username` / `redhat_registry_password` | A **registry service account** at <https://access.redhat.com/terms-based-registry/>. Username looks like `12345678\|aap-demo`; password is the token. Your Red Hat login also works. |
| `redhat_offline_token` | **Offline token** from <https://access.redhat.com/management/api> ("Generate token"). Used for the Customer Portal API. Expires after 30 days of inactivity. |
| `redhat_subscription_allocation_uuid` (optional) | A **subscription allocation** at <https://access.redhat.com/management/subscription_allocations> (type: latest Satellite) with an AAP subscription attached. The UUID is in its URL/details. With it, the manifest is exported and applied during the install, so AAP is licensed on first login. Without it, log in and attach a subscription in the UI (Red Hat login or manifest upload). |

The screenshots in demo-packer-aap's [pre-reqs/README.md](https://github.com/hashicorp-redhat-apj/demo-packer-aap/blob/main/pre-reqs/README.md) walk through every one of these pages.

### Cost

Roughly US$0.55–0.75 per hour all-in in most regions: `m6i.2xlarge` on-demand + the RHEL hourly premium + 100 GiB gp3 + the public IPv4 charge. `terraform destroy` removes everything.

## Quick start (local)

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in the Red Hat values
terraform init
terraform apply
```

The apply takes 25–45 minutes: a couple of minutes for AWS, the rest is the installer on the node. The readiness gate prints a line every 30 seconds and the apply only finishes once the API answers.

```bash
terraform output aap_url
terraform output -raw aap_admin_password; echo
terraform output -raw ssh_private_key > aap.pem && chmod 600 aap.pem
```

Log in as `admin` at the URL. The certificate is self-signed, so expect a browser warning. If you did not pass a subscription allocation, the first screen asks you to attach a subscription (use your Red Hat login).

Watching the install:

```bash
$(terraform output -raw aap_status_command)          # pending | installing | ready | failed
$(terraform output -raw ssm_session_command)         # shell via Session Manager, no SSH needed
sudo tail -f /var/log/aap-install.log                # on the node
```

### Checking the configuration without AWS credentials

```bash
terraform init -backend=false
terraform validate
terraform test          # plans against mocked providers (tests/plan.tftest.hcl)
```

## How the bootstrap works

1. Terraform renders a small **cloud-config** (gzip + base64 user data) containing `install.env` (non-secret settings), an inventory *template*, and the static [install_aap.sh](modules/aap-node/scripts/install_aap.sh).
2. On first boot the script installs `ansible-core`, `podman`, the AWS CLI and the SSM Agent, waits for the Elastic IP to be attached, sets the hostname and `/etc/hosts`.
3. It reads the secrets from SSM Parameter Store with the instance role and creates the non-root `aap` installation user (passwordless sudo, `loginctl enable-linger`).
4. It fetches the installer: `aap_installer_s3_uri` > `aap_installer_url` > the Red Hat Customer Portal API (`/management/v1/images/cset/ansible-automation-platform-<ver>-for-rhel-<major>-x86_64-files`, newest `containerized-setup-<ver>-*` build). This is the same lookup the Red Hat CoP [`infra.aap_utilities.aap_setup_download`](https://github.com/redhat-cop/aap_utilities) role performs.
5. Optionally exports the manifest from your subscription allocation (RHSM API: `export` → `exportJob` → download) and sets `controller_license_file`.
6. Renders the final inventory with `envsubst` (secrets never touch user data), then runs `ansible-playbook -i inventory ansible.containerized_installer.install` as the `aap` user, retrying once on failure.
7. Verifies `https://<host>/api/controller/v2/ping/` with the admin credentials, writes `/etc/motd.d/aap`, sets the SSM `status` parameter and the `aap:status` instance tag to `ready`.

Generated inventory (growth topology, from [inventory.ini.tftpl](modules/aap-node/templates/inventory.ini.tftpl)):

```ini
[automationgateway]
[automationcontroller]
[automationhub]        # enable_automation_hub
[automationeda]        # enable_eda
[database]
[all:vars]
ansible_connection=local
redis_mode=standalone
controller_percent_memory_capacity=0.5
hub_seed_collections=false
controller_license_file=/opt/aap/manifest.zip   # when a manifest is configured
# + postgresql_*, registry_*, *_admin_password, *_pg_* and var.extra_inventory_vars
```

## Running in HCP Terraform / Terraform Enterprise

1. Create a workspace (VCS-driven or CLI-driven) pointing at this repo. Remote execution is fine: the readiness gate only needs `bash` and `curl`, which the hosted workers and the TFE agent image have.
2. Workspace variables:
   * Terraform variables: `redhat_registry_username`, `redhat_registry_password`, `redhat_offline_token` (all **sensitive**), optionally `redhat_subscription_allocation_uuid`, `aws_region`, `name`, `allowed_cidr_blocks` (HCL).
   * AWS credentials: [dynamic provider credentials](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/aws-configuration) (`TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_RUN_ROLE_ARN`) or static `AWS_*` environment variables, ideally in a variable set.
3. Either uncomment the `cloud {}` block in [versions.tf](versions.tf) or export `TF_CLOUD_ORGANIZATION` and `TF_WORKSPACE` (plus `TF_CLOUD_HOSTNAME` for TFE) before `terraform init`.
4. Queue a run. Expect it to sit in *apply* for ~30 minutes while the node installs; the provisioner output shows the polling.

Tips

* Mark `aap_admin_password` and `ssh_private_key` outputs as what they are: they are sensitive outputs and only visible to users with state read access.
* Add a **run trigger** from this workspace to any workspace that consumes AAP so they re-plan after a rebuild.
* On TFE with restricted egress, the agent must reach the AAP public IP on 443, or set `wait_for_aap = false` and gate downstream workspaces on the SSM `status` parameter instead.
* `terraform destroy` works from the workspace as usual; nothing is created outside Terraform's knowledge except the `status` parameter value, which is ignored.

## Using the AAP from other repositories

Outputs are designed to be consumed directly:

| Output | Use |
|---|---|
| `aap_url`, `aap_hostname` | Provider `host`, browser URL. |
| `aap_admin_username`, `aap_admin_password` (sensitive) | Provider credentials. |
| `aap_api_urls` | Gateway, controller, hub and EDA API bases. |
| `security_group_id`, `iam_role_name`, `vpc_id`, `subnet_id` | Let other workloads reach AAP or extend the node's permissions. |
| `ssm_parameter_prefix`, `aap_status_parameter_name` | Read `url`, `admin_password` and `status` from SSM without Terraform state access. |

**HCP Terraform / TFE** — see [examples/hcp-terraform-consumer](examples/hcp-terraform-consumer/main.tf):

```hcl
data "tfe_outputs" "aap" {
  organization = "my-org"
  workspace    = "aap-on-aws"
}

provider "aap" {
  host                 = data.tfe_outputs.aap.values.aap_url
  username             = data.tfe_outputs.aap.values.aap_admin_username
  password             = data.tfe_outputs.aap.values.aap_admin_password
  insecure_skip_verify = true
}
```

**Any backend** — `terraform_remote_state` works the same way, or export the values for the provider's environment variables:

```bash
export AAP_HOST=$(terraform output -raw aap_url)
export AAP_USERNAME=admin
export AAP_PASSWORD=$(terraform output -raw aap_admin_password)
export AAP_INSECURE_SKIP_VERIFY=true
```

**Without state access** (CI jobs, scripts):

```bash
aws ssm get-parameter --name /aap/aap-demo/url --query Parameter.Value --output text
aws ssm get-parameter --name /aap/aap-demo/admin_password --with-decryption --query Parameter.Value --output text
```

For the job-launch repo above, map `aap_url` → controller host, `admin` → username and `aap_admin_password` → password.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `name` | `aap-demo` | Resource prefix and SSM path. |
| `aws_region` | `ap-southeast-1` | |
| `allowed_cidr_blocks` | `["0.0.0.0/0"]` | 443/80/22 ingress. Restrict it. |
| `create_vpc` / `vpc_cidr` | `true` / `10.80.0.0/16` | Set `create_vpc=false` with `vpc_id` + `subnet_id` (public subnet, DNS hostnames enabled). |
| `instance_type` | `m6i.2xlarge` | Minimum per Red Hat: 4 vCPU / 16 GiB. |
| `root_volume_size_gb` | `100` | Minimum 60. |
| `rhel_major_version` / `ami_id` | `9` / latest Red Hat AMI | RHEL 10 is also supported by AAP 2.6. |
| `key_name` | generated | Existing EC2 key pair name. |
| `enable_ssm_session_manager` | `true` | Session Manager access. |
| `aap_version` | `2.6` | Release stream used for the download lookup. |
| `aap_installer_type` | `setup` | `setup-bundle` for the offline bundle (also sets `bundle_install`/`bundle_dir`). |
| `aap_installer_s3_uri` / `aap_installer_url` | `null` | Bring your own tarball (air-gapped or faster). |
| `aap_hostname` / `route53_zone_id` | EIP public DNS | Friendly FQDN with a Route 53 A record. |
| `aap_admin_password` | generated (20 chars) | Shared by gateway/controller/hub/EDA. |
| `enable_automation_hub` / `enable_eda` | `true` / `true` | Turn off for a lighter controller-only node. |
| `hub_seed_collections` | `false` | Seeding the bundled collections adds a lot of time. |
| `extra_inventory_vars` | `{}` | Any installer variable, e.g. the `controller_postinstall*` configuration-as-code settings. |
| `wait_for_aap` / `wait_timeout_minutes` | `true` / `60` | Readiness gate. |
| `redhat_registry_username` / `redhat_registry_password` | required | registry.redhat.io. |
| `redhat_offline_token` | required unless BYO tarball | Customer Portal API. |
| `redhat_subscription_allocation_uuid` / `aap_manifest_s3_uri` | `null` | Apply a subscription during the install. |

The reusable part lives in [modules/aap-node](modules/aap-node); the root module only adds the VPC. Point `source` at `github.com/<you>/<repo>//modules/aap-node` to embed the node in another configuration with your own network.

## Operations

* **Stop/start**: safe; the Elastic IP keeps the hostname and certificates valid.
* **Rebuild**: `terraform apply -replace=module.aap.module.ec2.aws_instance.this[0]` reinstalls on a fresh instance with the same IP/hostname. Changing anything that alters user data (installer type, hostname, components, extra vars) also triggers a replacement because `user_data_replace_on_change` is on.
* **Changing the admin password after install**: Terraform updates the SSM parameter, not the running AAP. Either rebuild or change it in AAP as well.
* **Install failed**: `aap_status_command` shows `failed`; the log is `/var/log/aap-install.log` (bootstrap) and `/home/aap/aap/…` / `~aap/.ansible` for installer details. Re-run `sudo -iu aap /opt/aap/run-installer.sh` after fixing the cause; the installer is idempotent.
* **Red Hat token expired**: offline tokens expire after 30 days without use. Generate a new one and rebuild.
* **Destroy**: `terraform destroy` removes everything including the EIP and the SSM parameters.

## Security notes (demo defaults)

* The security group is open to the world by default. Set `allowed_cidr_blocks`.
* AAP uses the installer's self-signed certificate. Clients need `insecure_skip_verify` or must trust the CA at `/home/aap/aap/tls/` on the node.
* Secrets are passed through SSM SecureString parameters (default `aws/ssm` key), never through user data, but they are also in Terraform state and outputs. Use HCP Terraform/TFE or an encrypted backend with restricted state access.
* IMDSv2 is enforced (hop limit 2 so execution environments can use the instance role).
* The node runs as a regular EC2 instance with outbound internet access to reach Red Hat; there is no NAT or proxy in the path.

## Limitations

* Single node, growth topology only. No HA, no external database, no custom TLS certificates.
* x86_64 only (the AMI lookup and the AWS CLI download assume it).
* The readiness gate relies on a `local-exec` provisioner; Windows users should run Terraform from WSL or set `wait_for_aap = false`.

## References

* Red Hat, [Containerized installation (AAP 2.6)](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/containerized_installation/index) and [Container growth topology](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/plan-ref_cont_a_env_a)
* Red Hat CoP, [infra.aap_utilities](https://github.com/redhat-cop/aap_utilities) (download / prepare / install roles this bootstrap mirrors)
* Red Hat, [Using APIs in Red Hat Subscription Management](https://docs.redhat.com/en/documentation/subscription_central/1-latest/html-single/using_apis_in_red_hat_subscription_management/index) (offline token, allocations, manifest export)
* AWS, [Install SSM Agent on RHEL 8/9/10](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-rhel-8-9.html)
* [hashicorp-redhat-apj/demo-packer-aap](https://github.com/hashicorp-redhat-apj/demo-packer-aap), [ansible/aap Terraform provider](https://registry.terraform.io/providers/ansible/aap/latest/docs)
