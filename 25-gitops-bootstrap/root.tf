# THE ROOT APPLICATION: the one object that points Argo CD at Git and starts the loop.
#
# "App of apps". An Argo CD Application says: "make the cluster look like THIS folder of THIS
# repository". The root application's folder (bootstrap/ in gatepass-gitops) contains more
# Applications (projects, Argo CD's own configuration, cluster configuration, later every
# platform add-on), each pointing at its own folder. One object created here therefore grows
# into the whole platform, and a new add-on is added by a pull request, not by a command.
#
# WHY A HELM RELEASE AND NOT kubernetes_manifest. kubernetes_manifest needs the Application
# custom resource definition to exist at PLAN time, which it does not on a new cluster (the
# definition arrives with the Argo CD install in the same run), so the first plan would fail.
# The small `argocd-apps` chart renders Application and AppProject objects from values and has
# no such need. It is a pinned chart like the other.
#
# TWO OBJECTS ARE CREATED
#
# 1. AppProject `bootstrap`. An AppProject is a fence around applications: which repositories
#    they may read, which clusters/namespaces they may write to, which kinds of object they may
#    create. The root application sits in the strictest fence there is: it may read only the
#    gitops repository, write only into the argocd namespace, and create only Application and
#    AppProject objects (no namespaces, no deployments, nothing cluster-wide). So even a
#    mistaken commit into bootstrap/ can only add or change applications, never directly
#    touch workloads; the applications it adds live in the wider `platform` and `apps`
#    projects (gatepass-gitops/projects/).
#
# 2. Application `root`. Source: the bootstrap/ folder, branch var.gitops_revision, read over
#    SSH with the deploy key from secrets.tf. Automated sync with
#      prune     = true   remove from the cluster what is removed from Git (deleting an
#                         application's file from bootstrap/ deletes that application);
#      selfHeal  = true   put back what someone changed by hand in the cluster.
#    The `resources-finalizer` makes deleting the root application cascade: its children (and
#    theirs) are deleted first, so removing the root really removes the platform. `make down`
#    relies on this (and Phase 3 stages it so load balancers disappear before the cluster).
#
# Related files: argocd.tf (before), variables.tf (repo URL, revision), the gitops repository
# (bootstrap/, projects/).

locals {
  in_cluster = "https://kubernetes.default.svc"
}

resource "helm_release" "root" {
  name       = "argocd-root"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    projects = {
      bootstrap = {
        namespace   = "argocd"
        description = "The root application and the applications it creates. Strictest fence: Application and AppProject objects only, in the argocd namespace."
        sourceRepos = [var.gitops_repo_url]
        destinations = [{
          server    = local.in_cluster
          namespace = "argocd"
        }]
        clusterResourceWhitelist = []
        namespaceResourceWhitelist = [
          { group = "argoproj.io", kind = "Application" },
          { group = "argoproj.io", kind = "AppProject" },
        ]
      }
    }

    applications = {
      root = {
        namespace  = "argocd"
        project    = "bootstrap"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "bootstrap"
        }
        destination = {
          server    = local.in_cluster
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["ServerSideApply=true"]
          retry = {
            limit = 5
            backoff = {
              duration    = "30s"
              factor      = 2
              maxDuration = "5m"
            }
          }
        }
      }
    }
  })]

  wait    = true
  atomic  = true
  timeout = 300

  depends_on = [helm_release.argocd]
}
