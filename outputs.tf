output "auth_mode" {
  description = "How the workflow will authenticate to the cluster."
  value       = module.github_config.auth_mode
}

output "service_account" {
  description = "Identity experiments run as inside the cluster."
  value       = module.cluster_access.service_account
}

output "allowed_namespaces" {
  description = "The only namespaces an experiment can target."
  value       = var.allowed_namespaces
}

output "node_faults_enabled" {
  description = "Whether node-drain and zone-outage were granted."
  value       = module.cluster_access.node_faults_enabled
}

output "live_requires_approval" {
  description = "Whether a live run waits for a reviewer."
  value       = module.github_config.live_requires_approval
}

output "role_arn" {
  description = "IAM role assumed by GitHub Actions, when using OIDC."
  value       = var.auth_mode == "oidc" ? module.aws_oidc[0].role_arn : null
}

output "trusted_subjects" {
  description = "Exactly which workflow identities can assume that role."
  value       = var.auth_mode == "oidc" ? module.aws_oidc[0].trusted_subjects : []
}

output "next_step" {
  description = "What to do once this has applied."
  value       = "kubectl apply -f ../demo/app.yaml, then run node-drain against app=frontend with min_ready=3. It should fail. Apply ../demo/hardened.yaml and run it again."
}
