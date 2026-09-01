terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# Short-lived credentials federated from GitHub, so no long-lived cluster
# credential is stored in a repository secret at all.

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "target" {
  name = var.eks_cluster_name
}

# GitHub's OIDC provider is one per account. Reuse it if it already exists.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.oidc_thumbprints

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # The trust is pinned to one repository and one environment. A workflow run
  # outside the chaos-live environment cannot assume this role, which is what
  # makes the environment approval gate a real security boundary rather than a
  # convenience.
  subjects = [
    for env in var.allowed_environments :
    "repo:${var.github_owner}/${var.github_repository}:environment:${env}"
  ]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

data "aws_iam_policy_document" "eks_describe" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [data.aws_eks_cluster.target.arn]
  }
}

resource "aws_iam_role" "chaos" {
  name                 = var.role_name
  description          = "ChaosLab experiments dispatched from GitHub Actions"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy" "eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.chaos.id
  policy = data.aws_iam_policy_document.eks_describe.json
}

# Map the role into the cluster. Kubernetes RBAC — created by the
# cluster-access module — decides what it can actually do once inside.
resource "aws_eks_access_entry" "chaos" {
  count = var.create_access_entry ? 1 : 0

  cluster_name      = var.eks_cluster_name
  principal_arn     = aws_iam_role.chaos.arn
  kubernetes_groups = var.kubernetes_groups
  type              = "STANDARD"
  tags              = var.tags
}
