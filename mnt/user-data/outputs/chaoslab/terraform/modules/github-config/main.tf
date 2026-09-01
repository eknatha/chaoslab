terraform {
  required_version = ">= 1.5"
  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 6.2"
    }
  }
}

# Everything the live-mode setup section of the README asks you to click
# through, expressed as code.

resource "github_repository_environment" "dry" {
  repository  = var.repository
  environment = "chaos-dry"
}

resource "github_repository_environment" "live" {
  repository  = var.repository
  environment = "chaos-live"

  # Live runs wait for a human. With OIDC in play this is also the security
  # boundary: the AWS trust policy federates on this environment claim.
  dynamic "reviewers" {
    for_each = length(var.live_reviewer_user_ids) > 0 || length(var.live_reviewer_team_ids) > 0 ? [1] : []
    content {
      users = var.live_reviewer_user_ids
      teams = var.live_reviewer_team_ids
    }
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# Namespace allowlist. With this set, an experiment against anything else is
# refused before the cluster is contacted.
resource "github_actions_variable" "allowed_namespaces" {
  repository    = var.repository
  variable_name = "CHAOS_ALLOWED_NAMESPACES"
  value         = join(" ", var.allowed_namespaces)
}

# ── OIDC path ──────────────────────────────────────────────────────────
resource "github_actions_variable" "aws_role_arn" {
  count = var.aws_role_arn == "" ? 0 : 1

  repository    = var.repository
  variable_name = "AWS_ROLE_ARN"
  value         = var.aws_role_arn
}

resource "github_actions_variable" "aws_region" {
  count = var.aws_role_arn == "" ? 0 : 1

  repository    = var.repository
  variable_name = "AWS_REGION"
  value         = var.aws_region
}

resource "github_actions_variable" "eks_cluster_name" {
  count = var.aws_role_arn == "" ? 0 : 1

  repository    = var.repository
  variable_name = "EKS_CLUSTER_NAME"
  value         = var.eks_cluster_name
}

# ── Stored kubeconfig path ─────────────────────────────────────────────
# Only written when OIDC is not in use. Prefer OIDC where you can.
resource "github_actions_secret" "kubeconfig" {
  count = var.kubeconfig_base64 == "" ? 0 : 1

  repository      = var.repository
  secret_name     = "KUBECONFIG_DATA"
  plaintext_value = var.kubeconfig_base64
}

resource "github_actions_secret" "cluster_context" {
  count = var.kubeconfig_base64 == "" ? 0 : 1

  repository      = var.repository
  secret_name     = "CLUSTER_CONTEXT"
  plaintext_value = var.cluster_context
}
