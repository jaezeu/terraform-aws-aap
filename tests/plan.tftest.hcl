# Plan-time smoke tests with mocked providers: no AWS credentials or network
# access to AWS needed. Run with `terraform test`.
#
# They exercise variable validation, the for_each/count rules around sensitive
# values, template rendering and both VPC modes. They do not prove the AAP
# install works; that needs a real apply.

mock_provider "aws" {
  # Mocked data sources return random strings by default; a few attributes
  # are validated by the provider schema (policy JSON) or make assertions
  # readable, so give them realistic values.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}

variables {
  redhat_registry_username = "12345678|mock"
  redhat_registry_password = "mock-registry-token"
  redhat_offline_token     = "mock-offline-token"
  allowed_cidr_blocks      = ["203.0.113.0/24"]
}

run "defaults_new_vpc" {
  command = plan

  assert {
    condition     = module.aap.aap_admin_username == "admin"
    error_message = "admin username must be admin"
  }

  assert {
    condition     = module.aap.ssm_parameter_prefix == "/aap/aap-demo"
    error_message = "SSM prefix must follow /aap/<name>"
  }

  assert {
    condition     = module.aap.aap_api_urls.eda != null && module.aap.aap_api_urls.hub != null
    error_message = "hub and EDA are enabled by default"
  }
}

run "existing_vpc_bundle_manifest_route53" {
  command = plan

  variables {
    create_vpc                          = false
    vpc_id                              = "vpc-0123456789abcdef0"
    subnet_id                           = "subnet-0123456789abcdef0"
    wait_for_aap                        = false
    enable_eda                          = false
    enable_automation_hub               = false
    aap_installer_type                  = "setup-bundle"
    aap_hostname                        = "aap.demo.example.com"
    route53_zone_id                     = "Z0123456789ABCDEFGHIJ"
    aap_admin_password                  = "SuperSecret-123"
    key_name                            = "my-existing-key"
    redhat_subscription_allocation_uuid = "7f4075b9-38ac-46e3-986d-bf481d1853be"
    aap_manifest_s3_uri                 = "s3://my-bucket/manifest_aap_demo.zip"
    extra_inventory_vars = {
      controller_postinstall = "true"
    }
  }

  assert {
    condition     = module.aap.aap_url == "https://aap.demo.example.com"
    error_message = "a custom hostname must drive the URL"
  }

  assert {
    condition     = module.aap.aap_api_urls.eda == null && module.aap.aap_api_urls.hub == null
    error_message = "disabled components must not expose API URLs"
  }

  assert {
    condition     = module.aap.key_name == "my-existing-key"
    error_message = "an existing key pair must be used as-is"
  }
}

run "byo_installer_without_offline_token" {
  command = plan

  variables {
    redhat_offline_token = null
    aap_installer_s3_uri = "s3://my-bucket/ansible-automation-platform-containerized-setup-2.6-7.tar.gz"
    wait_for_aap         = false
  }
}

run "rejects_missing_installer_source" {
  command = plan

  variables {
    redhat_offline_token = null
  }

  expect_failures = [var.redhat_offline_token]
}

run "rejects_existing_vpc_without_subnet" {
  command = plan

  variables {
    create_vpc = false
    vpc_id     = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.subnet_id]
}
