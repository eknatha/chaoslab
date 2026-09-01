terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
  }
}

# A service account scoped to the namespaces you are willing to break, rather
# than the cluster-admin kubeconfig sitting on your laptop.

resource "kubernetes_service_account_v1" "chaos" {
  metadata {
    name      = var.service_account_name
    namespace = var.service_account_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "chaoslab"
    }
  }
}

# Namespaced permissions: everything the pod-level and network faults need,
# and nothing else. No secrets, no configmaps, no cluster scope.
resource "kubernetes_role_v1" "chaos" {
  for_each = toset(var.target_namespaces)

  metadata {
    name      = "chaoslab"
    namespace = each.value
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "events"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  # Eviction rather than deletion, so PodDisruptionBudgets are honoured.
  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec", "pods/portforward"]
    verbs      = ["create", "get"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "daemonsets", "replicasets", "statefulsets"]
    verbs      = ["get", "list", "watch", "create", "delete", "patch", "update"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "list", "create", "delete"]
  }

  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "chaos" {
  for_each = toset(var.target_namespaces)

  metadata {
    name      = "chaoslab"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.chaos[each.value].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.chaos.metadata[0].name
    namespace = kubernetes_service_account_v1.chaos.metadata[0].namespace
  }
}

# Reading nodes is needed by every fault, if only to resolve which node hosts
# a pod. This is read-only.
resource "kubernetes_cluster_role_v1" "read_nodes" {
  metadata {
    name = "chaoslab-read-nodes"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "read_nodes" {
  metadata {
    name = "chaoslab-read-nodes"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.read_nodes.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.chaos.metadata[0].name
    namespace = kubernetes_service_account_v1.chaos.metadata[0].namespace
  }
}

# node-drain and zone-outage need to cordon and evict across the cluster.
# That is a real privilege escalation, so it is opt-in and separate.
resource "kubernetes_cluster_role_v1" "node_faults" {
  count = var.allow_node_faults ? 1 : 0

  metadata {
    name = "chaoslab-node-faults"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "node_faults" {
  count = var.allow_node_faults ? 1 : 0

  metadata {
    name = "chaoslab-node-faults"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.node_faults[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.chaos.metadata[0].name
    namespace = kubernetes_service_account_v1.chaos.metadata[0].namespace
  }
}

# A bound token with a fixed lifetime, rather than a legacy never-expiring
# service account secret.
resource "kubernetes_token_request_v1" "chaos" {
  count = var.emit_kubeconfig ? 1 : 0

  metadata {
    name      = kubernetes_service_account_v1.chaos.metadata[0].name
    namespace = kubernetes_service_account_v1.chaos.metadata[0].namespace
  }

  spec {
    expiration_seconds = var.token_ttl_seconds
  }

  depends_on = [kubernetes_role_binding_v1.chaos]
}

locals {
  kubeconfig = var.emit_kubeconfig ? yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = merge(
        { server = var.cluster_endpoint },
        var.cluster_ca_certificate == "" ? { insecure-skip-tls-verify = true } : { certificate-authority-data = base64encode(var.cluster_ca_certificate) }
      )
    }]
    users = [{
      name = "chaoslab"
      user = { token = kubernetes_token_request_v1.chaos[0].token }
    }]
    contexts = [{
      name = var.cluster_name
      context = {
        cluster   = var.cluster_name
        user      = "chaoslab"
        namespace = var.service_account_namespace
      }
    }]
    "current-context" = var.cluster_name
  }) : ""
}
