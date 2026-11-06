# AWS permissions of the External Secrets Operator (ESO): the in-cluster program that copies
# a secret from AWS Secrets Manager into a Kubernetes Secret, on a schedule, so a Deployment
# can use it as an environment variable or a file without the value ever being in Git.
#
# Why ESO and not the CSI driver the course used (Secrets Store CSI + AWS provider): ESO
# produces ordinary Kubernetes Secrets (so Helm charts, HPA and the usual `secretKeyRef` work),
# refreshes them without a pod restart being required by the driver, and needs no DaemonSet. The
# CSI driver mounts the secret only into pods that ask for a volume, which is a fine second
# tool and stays in the plan as an alternative to compare in Phase 6.
#
# LEAST PRIVILEGE: read-only (GetSecretValue + DescribeSecret) on secrets whose name starts
# with var.eso_secret_prefix + "/" (default gatepass/dev/app/). The Argo CD secrets of
# 25-gitops-bootstrap live under gatepass/dev/argocd/ and are NOT readable by ESO, so a
# mistake in an ExternalSecret manifest cannot copy the GitHub deploy key into a namespace
# where a service could read it. The ARN ends in `-*` because Secrets Manager appends a random
# six-character suffix to every secret ARN.
#
# KMS. The secrets are encrypted with the environment key alias/gatepass-dev (created in
# 00-bootstrap), a customer-managed key, so reading one also needs kms:Decrypt on THAT key,
# and only when the request comes through Secrets Manager (kms:ViaService). Found on the first
# run, 2026-11-06: without this the ExternalSecret says SecretSyncedError and the operator log
# says "AccessDeniedException: Access to KMS is not allowed".
#
# Related files: pod-identity.tf (role, trust, association: namespace external-secrets,
# service account external-secrets), gatepass-gitops/platform/external-secrets (the install)
# and platform/cluster-config/secretstore-aws.yaml (the ClusterSecretStore that uses this role).

data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${var.eso_secret_prefix}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.env.target_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.workload["external-secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}
