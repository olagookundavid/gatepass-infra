# ARGO CD ITSELF, installed once by Terraform from the official Helm chart.
#
# WHY TERRAFORM INSTALLS IT. Argo CD is the thing that installs everything else inside the
# cluster, so something else has to install Argo CD: this is the "chicken and egg" of GitOps.
# Terraform does it once per cluster; after that Argo CD manages itself from Git (the
# `platform-argocd` application in gatepass-gitops). Terraform's job ends at: Argo CD runs, it
# can read the repository, and it has been told which folder to start from (root.tf).
#
# PINNED. `version` is the chart version (variables.tf), not "latest": an unpinned chart gives
# a different Argo CD after every rebuild. The course installed from a `stable` manifest URL;
# that is exactly the habit this replaces.
#
# WAIT AND ATOMIC. `wait = true` makes Terraform return only when every pod is ready;
# `atomic = true` rolls the release back if that does not happen in `timeout`, instead of
# leaving a half-installed Argo CD for the next apply to trip over.
#
# CRDs. The chart installs Argo CD's custom resource definitions (Application, AppProject,
# ApplicationSet) and keeps them when the release is uninstalled (crds.keep). On a fresh
# cluster each night this is irrelevant; on a long-lived cluster it prevents a `helm uninstall`
# from deleting every Application in the cluster.
#
# depends_on: the Secrets and the RBAC ConfigMap must exist first, because Argo CD reads them
# at start (repository credential, Dex client, notifier) and the chart is told not to create
# its own versions (argocd-bootstrap-values.yaml).
#
# Related files: namespace.tf, secrets.tf, rbac.tf (before); root.tf (after);
# argocd-bootstrap-values.yaml (the values).

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [file("${path.module}/argocd-bootstrap-values.yaml")]

  wait    = true
  atomic  = true
  timeout = 600

  depends_on = [
    kubernetes_secret_v1.gitops_repo,
    kubernetes_secret_v1.dex_github,
    kubernetes_secret_v1.notifications,
    kubernetes_config_map_v1.rbac,
  ]
}
