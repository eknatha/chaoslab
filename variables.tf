variable "auth_mode" {
  description = "How GitHub Actions reaches the cluster: oidc for EKS with federated credentials, kubeconfig for anything else."
  type        = string
  default     = "kubeconfig"

  validation {
    condition     = contains(["oidc", "kubeconfig"], var.auth_mode)
    error_message = "auth_mode must be either oidc or kubeconfig."
  }
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the fork."
  type        = string
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
  default     = "chaoslab"
}

variable "allowed_namespaces" {
  description = "The only namespaces experiments may target."
  type        = list(string)
  default     = ["chaos-demo"]
}

variable "enabled_faults" {
  description = "Faults you intend to run. Including node-drain or zone-outage grants cluster-wide cordon rights."
  type        = list(string)
  default = [
    "pod-kill", "container-kill", "cpu-stress", "memory-stress",
    "disk-fill", "net-delay", "net-loss", "dns-blackhole",
  ]

  validation {
    condition = length(setsubtract(toset(var.enabled_faults), toset([
      "pod-kill", "container-kill", "cpu-stress", "memory-stress", "disk-fill",
      "net-delay", "net-loss", "dns-blackhole", "node-drain", "zone-outage",
    ]))) == 0
    error_message = "Unknown fault name. Check the fault table in the README."
  }
}

variable "live_reviewer_user_ids" {
  description = "Numeric GitHub user IDs who may approve a live run. Leave empty to run without approval."
  type        = list(number)
  default     = []
}

variable "live_reviewer_team_ids" {
  description = "Numeric GitHub team IDs who may approve a live run."
  type        = list(number)
  default     = []
}

# ── OIDC mode ──────────────────────────────────────────────────────────
variable "aws_region" {
  description = "Region of the EKS cluster."
  type        = string
  default     = "ap-south-1"
}

variable "eks_cluster_name" {
  description = "EKS cluster name, required when auth_mode is oidc."
  type        = string
  default     = ""
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string
  default     = "chaoslab-github-actions"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to AWS resources."
  type        = map(string)
  default     = { managed-by = "terraform", part-of = "chaoslab" }
}

# ── kubeconfig mode ────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Context name written into the generated kubeconfig."
  type        = string
  default     = "chaoslab"
}

variable "cluster_endpoint" {
  description = "API server URL, required when auth_mode is kubeconfig."
  type        = string
  default     = ""
}

variable "cluster_ca_certificate" {
  description = "PEM-encoded cluster CA. Leave empty only for a local kind cluster."
  type        = string
  default     = ""
}

variable "token_ttl_seconds" {
  description = "Lifetime of the minted service account token. Re-apply to rotate."
  type        = number
  default     = 7776000
}

# ── local provider config ──────────────────────────────────────────────
variable "kubeconfig_path" {
  description = "Kubeconfig Terraform itself uses to create RBAC. Your own admin credentials, not the chaos ones."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Context within that kubeconfig."
  type        = string
  default     = ""
}
