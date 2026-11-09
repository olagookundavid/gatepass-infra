# THE PUBLIC ADDRESS OF ARGO CD, written into two ConfigMaps that the chart creates.
#
# WHY THIS IS NOT IN THE VALUES IN GIT. Argo CD needs to know the address people use to reach it:
#   argocd-cm            `url`      where GitHub sends the browser back after login (the OAuth
#                                   callback is <url>/api/dex/callback), and the base of links;
#   argocd-notifications-cm  `context`  the address printed in the Slack messages.
# That address is https://argocd.<domain>, and the gitops repository is public and does not
# publish the domain. So, like the RBAC ConfigMap with the e-mail address (rbac.tf), these two
# values are owned by Terraform (from terraform.tfvars) and the Git values simply do not set them.
#
# HOW TWO OWNERS CAN SHARE ONE ConfigMap. `kubernetes_config_map_v1_data` sets only the listed KEYS
# of an existing ConfigMap, under its own field manager name; the keys the chart (and later Argo
# CD's self-management) writes stay theirs. `force = true` takes a key over if another manager
# already holds it. Argo CD syncs these two ConfigMaps from Git with server-side apply, which
# changes only the fields Git names, so it leaves `url` and `context` alone.
#
# BEFORE THE LOAD BALANCER EXISTS the address does not answer yet; SSO and the Slack links work
# only once the Ingress (gatepass-gitops platform-ingresses) and the DNS record exist. Until
# then the port-forward still reaches the UI (login by SSO needs the callback on this address).
#
# Related files: argocd.tf (the chart), cluster.tf (the domain annotation that the ApplicationSets
# use), gatepass-gitops/platform/argocd/values.yaml (does NOT set url or argocdUrl).

resource "kubernetes_config_map_v1_data" "argocd_url" {
  metadata {
    name      = "argocd-cm"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    url = "https://argocd.${var.domain}"
  }

  field_manager = "terraform-gatepass"
  force         = true

  depends_on = [helm_release.argocd]
}

resource "kubernetes_config_map_v1_data" "argocd_notifications_context" {
  metadata {
    name      = "argocd-notifications-cm"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    context = "argocdUrl: https://argocd.${var.domain}\n"
  }

  field_manager = "terraform-gatepass"
  force         = true

  depends_on = [helm_release.argocd]
}
