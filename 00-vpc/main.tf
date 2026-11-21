module "vpc" {
  source      = "git::https://github.com/rajeshchakali63-netizen/terraform-aws-vpc.git?ref=main"
  project     = var.project
  environment = var.environment
}

