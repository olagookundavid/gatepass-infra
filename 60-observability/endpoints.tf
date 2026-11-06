# The addresses of the metrics workspace and the log group, stored in Secrets Manager so the
# cluster can copy them in WITHOUT writing them in the (public) gitops repository.
#
# They are not passwords. They are kept out of Git because they contain the workspace id and
# the project rule is "no resource addresses of my account in a public repository". The path is
# under gatepass/dev/app/, the only prefix the External Secrets Operator may read
# (30-platform-aws/external-secrets.tf), and the secret is encrypted with the environment key
# (the operator's role may decrypt with it, same file).
#
# In the cluster: gatepass-gitops/platform/observability/externalsecrets.yaml copies each field
# into the Secret `observability-endpoints`, which the collectors and Grafana read as
# environment variables. The values end up in this layer's Terraform state (they are not
# sensitive: knowing a workspace id grants nothing without IAM permission).
#
# Related files: amp.tf (the workspace), logs.tf (the log group), outputs.tf (the same values).

resource "aws_secretsmanager_secret" "endpoints" {
  name                    = "gatepass/${var.environment}/app/observability-endpoints"
  description             = "Addresses of the metrics workspace and the application log group (not secret values; kept out of the public Git repository)."
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "endpoints" {
  secret_id = aws_secretsmanager_secret.endpoints.id
  secret_string = jsonencode({
    amp_remote_write_url  = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
    amp_query_url         = aws_prometheus_workspace.main.prometheus_endpoint
    application_log_group = aws_cloudwatch_log_group.application.name
  })
}
