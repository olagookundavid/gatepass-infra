# The namespace Argo CD lives in.
#
# Terraform creates it (and not the Helm release with create_namespace) because the Secrets and
# the RBAC ConfigMap in secrets.tf and rbac.tf must exist in it BEFORE Argo CD starts, and
# because the labels below are ours to set.
#
# POD SECURITY LABELS (Kubernetes' built-in admission check on pod specs):
#   enforce = baseline    pods that break the baseline rules (privileged, host network...) are
#                         rejected;
#   warn / audit = restricted
#                         pods that would not pass the stricter "restricted" profile are
#                         allowed, but a warning is printed and the API server audit log notes
#                         it. Argo CD's pods are written to pass "restricted" (non-root, no
#                         privilege escalation, dropped capabilities, seccomp), so the warnings
#                         should stay silent; if they do not, that is worth a look before the
#                         namespace is ever switched to enforce = restricted (a Phase 6 task).
#
# Related files: argocd.tf installs into this namespace; secrets.tf and rbac.tf put objects in it.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"

    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}
