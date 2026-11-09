# Values for humans. The services read the same facts from the secret in config.tf.

output "config_secret" {
  value = aws_secretsmanager_secret.config.name
}

output "db_endpoint" {
  description = "PostgreSQL host name (changes at every rebuild)."
  value       = aws_db_instance.this.address
}

output "db_resource_id" {
  description = "The id inside rds-db:connect ARNs."
  value       = aws_db_instance.this.resource_id
}

output "cache_endpoint" {
  value = "${aws_elasticache_serverless_cache.this.endpoint[0].address}:${aws_elasticache_serverless_cache.this.endpoint[0].port}"
}
