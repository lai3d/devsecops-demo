# Lets GitHub Actions in this repository assume an AWS role with a short-lived
# OIDC token instead of stored access keys. Apply once, by hand, with an admin
# profile; then set the repository variable AWS_ROLE_ARN to the output.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "repository" {
  description = "owner/name of the GitHub repository allowed to assume the role"
  type        = string
  default     = "lai3d/devsecops-demo"
}

variable "create_oidc_provider" {
  description = "false if the account already has the GitHub OIDC provider"
  type        = bool
  default     = true
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only workflows running on main in this one repository. Pull requests and
    # other branches get a different "sub" and are refused.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.repository}:ref:refs/heads/main"]
    }
  }
}

# No permissions are attached: the check workflow only calls
# sts:GetCallerIdentity, which needs none. Attach narrowly scoped policies
# here when a workflow needs to do real work.
resource "aws_iam_role" "github_actions" {
  name                 = "github-actions-devsecops-demo"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

output "role_arn" {
  value = aws_iam_role.github_actions.arn
}
