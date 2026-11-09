# The in-cluster entry of Argo CD, with two LABELS/ANNOTATIONS the ApplicationSet reads.
#
# Argo CD knows the cluster it runs in as the built-in "in-cluster" (https://kubernetes.default.svc).
# A cluster Secret with exactly that server URL replaces the built-in entry, which is the only
# way to attach metadata to it. The ApplicationSet of gatepass-gitops
# (platform/services/applicationset.yaml) selects it by the label gatepass.dev/environment=dev and
# reads the annotation gatepass.dev/ecr-registry to build every service's image address.
#
# WHY HERE and not in Git: the registry host contains the AWS account id, and the Git repository
# is public (project rule: no account id in a public repository). Terraform knows the account and
# the region, so it writes the value into the cluster; Git only ever says "read it from there".
# It is not a secret (an account id is not), it is just not published.
#
# `config` has no credentials: Argo CD uses its own service account for the local cluster.
#
# Related files: namespace.tf (where it goes), argocd.tf (Argo CD must exist to read it),
# gatepass-gitops/platform/services/applicationset.yaml (the reader).

resource "kubernetes_secret_v1" "in_cluster" {
  metadata {
    name      = "cluster-in-cluster"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "gatepass.dev/environment"       = var.environment
    }

    annotations = {
      "gatepass.dev/ecr-registry" = "${var.allowed_account_id}.dkr.ecr.${var.region}.amazonaws.com"
      # The delegated subdomain (Phase 6b). The ApplicationSets read it to build host names such as
      # api.<domain> without the domain being written in the public gatepass-gitops repository.
      "gatepass.dev/domain" = var.domain
    }
  }

  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
}
