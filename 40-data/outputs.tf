# Values for humans and for the next layers (which look the resources up by NAME rather than read this
# layer's state). The full list of published keys is in config.tf.

output "config_secret" {
  description = "Secrets Manager secret with every value the services need from this layer."
  value       = aws_secretsmanager_secret.config.name
}

output "reservations_table" {
  value = aws_dynamodb_table.reservations.name
}

output "notifications_table" {
  value = aws_dynamodb_table.notifications.name
}

output "event_bus" {
  value = aws_cloudwatch_event_bus.this.name
}

output "queue_urls" {
  value = { for q, _ in local.queues : q => aws_sqs_queue.main[q].url }
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.app.id
}

output "cdn_url" {
  value = "https://cdn.${var.domain}"
}

output "ses_dkim_status" {
  description = "SUCCESS once SES has found the three DKIM records in DNS (a few minutes after the apply)."
  value       = aws_sesv2_email_identity.domain.dkim_signing_attributes[0].status
}
