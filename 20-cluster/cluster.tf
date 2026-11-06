# The EKS cluster: the Kubernetes control plane (API server, scheduler, etcd) that AWS runs for
# us. This file is the one to read most carefully; every setting here is a decision.
#
# WHAT THE CONTROL PLANE IS. We never see its servers. We get an API endpoint (what kubectl,
# Argo CD and Terraform talk to) and the nodes (nodes.tf) join it. Cost: about $0.10 per hour
# ($2.40 a day) for as long as the cluster exists, which is why `make down` removes it nightly.
#
# THE DECISIONS (and what the course did instead; PLAN section 16, "Do not copy")
#   Authentication  authentication_mode = "API": who may use the cluster is decided ONLY by
#                   EKS access entries (access.tf), which are AWS objects with an audit trail.
#                   The course used API_AND_CONFIG_MAP and the aws-auth ConfigMap, a YAML file
#                   inside the cluster that can be broken with one bad edit and locks everyone
#                   out. bootstrap_cluster_creator_admin_permissions = false: no hidden admin
#                   for "whoever ran Terraform"; the only admin is the one written in code.
#   API endpoint    public, but ONLY from api_allowed_cidrs (your address); the course allowed
#                   0.0.0.0/0. The PRIVATE endpoint is also on, and that is essential: the nodes
#                   (in private subnets) reach the API through it. With the private endpoint
#                   off, nodes would call the public endpoint through the NAT, whose address is
#                   not in the allowed list, and they would never join.
#   Secrets         encryption_config: every Kubernetes Secret is envelope-encrypted with our KMS
#                   key before it is stored in etcd (the course left this off).
#   Logs            all five control-plane log types go to a log group WE create, with
#                   retention and the KMS key. If the cluster created its own log group it would
#                   keep logs forever and survive `make down` (a cost that never ends).
#   Add-ons         bootstrap_self_managed_addons = false: EKS does NOT install its default
#                   networking add-ons on its own; addons.tf installs each one, pinned, as a
#                   managed add-on from the start. (This setting cannot be changed later
#                   without re-creating the cluster.)
#   Support         upgrade_policy STANDARD: when a Kubernetes version leaves standard support,
#                   the cluster is upgraded to the next version instead of staying on a version
#                   that is charged extra per hour ("extended support").
#   Network         service_ipv4_cidr 172.20.0.0/16 is the range for ClusterIP addresses. It is
#                   virtual (only inside the cluster) but must not overlap the VPC (10.20.0.0/16).
#
# Related files: iam.tf (the cluster role and key permission), data.tf (subnets and key),
# access.tf (who is admin), nodes.tf and addons.tf (what runs on and in it).

resource "aws_cloudwatch_log_group" "cluster" {
  # This exact name is the one EKS writes to; a differently named group would be ignored.
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = data.aws_kms_alias.env.target_key_arn
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    # The control plane puts network interfaces in these subnets. The private tier, three zones.
    subnet_ids = data.aws_subnets.private.ids

    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.api_allowed_cidrs
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = "172.20.0.0/16"
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = data.aws_kms_alias.env.target_key_arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  upgrade_policy {
    support_type = "STANDARD"
  }

  # The log group must exist (with our retention) BEFORE the cluster starts logging, and the
  # role must have its policies before the cluster is created, or creation fails or races.
  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
  ]
}
