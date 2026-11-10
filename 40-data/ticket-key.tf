# THE TICKET SIGNING KEY: the secret that turns a ticket into something nobody can forge.
#
# WHAT IT IS FOR. notifications-worker renders a ticket (a PNG with a QR code). The QR code holds a
# token signed with an HMAC key (a keyed hash): whoever has the key can issue a valid token, whoever
# does not cannot, and the gate scanner can verify a token with the same key. So the key is the one
# value that must never leave Secrets Manager: not in Git, not in an environment variable (a pod's
# environment is visible with `kubectl describe pod`), not in Terraform state.
#
# HOW IT REACHES THE POD. External Secrets copies it into a Kubernetes Secret and the chart mounts
# that Secret as a FILE (values key `secretFiles`, path /var/run/secrets/ticket/signing-key); the
# service reads TICKET_SIGNING_KEY_FILE. A file is the safer carrier than an environment variable:
# it does not show up in `kubectl describe`, in crash dumps of the environment or in child processes.
# The plain string is stored (no JSON), so the ExternalSecret row has no `property`.
#
# WHY NOT IN STATE. Same pattern as db-secrets.tf: an `ephemeral` random value handed to a write-only
# argument exists only while Terraform runs. Terraform cannot read it back, so rotation is explicit:
# raise secret_string_wo_version to write a new key. Rotating invalidates every ticket already issued
# (the contract says so), which is why the secret is persistent and nothing rotates it automatically;
# a production system would keep two keys (current and previous) so old tickets stay valid for a while.
#
# Related files: db-secrets.tf (same pattern), config.tf (the other secrets of this layer),
# gatepass-gitops apps/notifications-worker/values.yaml (the mount), charts/gatepass-service
# (templates/externalsecret-files.yaml). No IAM change: External Secrets reads the whole prefix
# gatepass/dev/app/ already (30-platform-aws/external-secrets.tf), the worker itself never calls
# Secrets Manager for this value.

ephemeral "random_password" "ticket_signing_key" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "ticket_signing_key" {
  name                    = "gatepass/${var.environment}/app/ticket-signing-key"
  description             = "HMAC key that signs the QR tokens of tickets (notifications-worker, mounted as a file)"
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ticket_signing_key" {
  secret_id                = aws_secretsmanager_secret.ticket_signing_key.id
  secret_string_wo         = ephemeral.random_password.ticket_signing_key.result
  secret_string_wo_version = 1
}
