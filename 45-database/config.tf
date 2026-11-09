# THE ADDRESS BOOK OF THE REBUILT PART: the values that change every time the database and the cache
# are recreated, published as one Secrets Manager secret for the services.
#
# Same idea as 40-data/config.tf, in a separate secret because the lifetime differs: `data-config`
# is stable between sessions, THIS one is created and destroyed with the layer (no recovery window).
# External Secrets copies keys from both into a service's environment, for example
#     {secretKey: DB_HOST, key: gatepass/dev/app/database-config, property: db_host}
#
# db_resource_id is the identifier that rds-db:connect ARNs contain (it changes at every rebuild, which
# is why the roles that use it are in 50-workloads, also rebuilt daily). db_master_secret_arn points
# at the secret RDS keeps for the master user; only the bootstrap Job may read it.
#
# Related files: rds.tf and cache.tf (the values), outputs.tf, 50-workloads (roles for these ARNs).

locals {
  config = {
    db_host                 = aws_db_instance.this.address
    db_port                 = tostring(aws_db_instance.this.port)
    db_resource_id          = aws_db_instance.this.resource_id
    db_master_secret_arn    = aws_db_instance.this.master_user_secret[0].secret_arn
    redis_addr              = "${aws_elasticache_serverless_cache.this.endpoint[0].address}:${aws_elasticache_serverless_cache.this.endpoint[0].port}"
    cache_name              = aws_elasticache_serverless_cache.this.name
    redis_user_catalog      = aws_elasticache_user.app["catalog"].user_name
    redis_user_reservations = aws_elasticache_user.app["reservations"].user_name
  }
}

resource "aws_secretsmanager_secret" "config" {
  name                    = "gatepass/${var.environment}/app/database-config"
  description             = "Addresses of the rebuilt data stores (45-database), read by External Secrets"
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id     = aws_secretsmanager_secret.config.id
  secret_string = jsonencode(local.config)
}
