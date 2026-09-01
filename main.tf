terraform {
  required_version = ">= 1.5"
  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 6.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# One apply replaces the whole live-mode setup checklist: RBAC, credentials,
# environments, approval gates and the namespace allowlist.
#
#   auth_mode = "oidc"       EKS with federated short-lived credentials
#   auth_mode = "kubeconfig" any cluster, including kind, with a scoped token

provider "github" {
  owner = var.github_owner
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

locals {
  use_oidc = var.auth_mode == "oidc"

  # node-drain and zone-outage need cluster-wide cordon rights. Only grant
  # them when the fault list actually asks for it.
  needs_node_faults = length(setintersection(
    toset(var.enabled_faults),
    toset(["node-drain", "zone-outage"])
  )) > 0
}

module "aws_oidc" {
  count  = local.use_oidc ? 1 : 0
  source = "./modules/aws-oidc"

  github_owner      = var.github_owner
  github_repository = var.github_repository
  eks_cluster_name  = var.eks_cluster_name
  role_name         = var.role_name

  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn
  tags                       = var.tags
}

module "cluster_access" {
  source = "./modules/cluster-access"

  cluster_name           = local.use_oidc ? var.eks_cluster_name : var.cluster_name
  cluster_endpoint       = local.use_oidc ? module.aws_oidc[0].cluster_endpoint : var.cluster_endpoint
  cluster_ca_certificate = local.use_oidc ? module.aws_oidc[0].cluster_ca_certificate : var.cluster_ca_certificate

  target_namespaces = var.allowed_namespaces
  allow_node_faults = local.needs_node_faults

  # With OIDC the role gets its identity from AWS, so no token is minted.
  emit_kubeconfig   = !local.use_oidc
  token_ttl_seconds = var.token_ttl_seconds
}

module "github_config" {
  source = "./modules/github-config"

  repository         = var.github_repository
  allowed_namespaces = var.allowed_namespaces

  live_reviewer_user_ids = var.live_reviewer_user_ids
  live_reviewer_team_ids = var.live_reviewer_team_ids

  aws_role_arn     = local.use_oidc ? module.aws_oidc[0].role_arn : ""
  aws_region       = local.use_oidc ? var.aws_region : ""
  eks_cluster_name = local.use_oidc ? var.eks_cluster_name : ""

  kubeconfig_base64 = local.use_oidc ? "" : module.cluster_access.kubeconfig_base64
  cluster_context   = local.use_oidc ? "" : module.cluster_access.context_name
}

# Map the federated role onto the same Kubernetes group the RBAC binds, so
# EKS access entries and cluster RBAC agree on what the role can do.
resource "kubernetes_cluster_role_binding_v1" "oidc_group" {
  count = local.use_oidc ? 1 : 0

  metadata {
    name = "chaoslab-oidc-group"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "chaoslab-read-nodes"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "chaoslab"
  }

  depends_on = [module.cluster_access]
}
