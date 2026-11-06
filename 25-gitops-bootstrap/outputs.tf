# What the layer publishes, for people: the walkthrough and the Makefile print these.

output "namespace" {
  description = "Namespace Argo CD runs in."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "port_forward_command" {
  description = "Run this, then open http://localhost:8080 and choose 'Log in via GitHub'. The server is plain HTTP inside the cluster; TLS comes with the Ingress in Phase 6b."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:80"
}

output "argocd_chart_version" {
  description = "The chart version that was installed."
  value       = helm_release.argocd.version
}
