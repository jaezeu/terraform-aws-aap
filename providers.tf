provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project   = var.name
        ManagedBy = "terraform"
        Component = "ansible-automation-platform"
      },
      var.tags,
    )
  }
}
