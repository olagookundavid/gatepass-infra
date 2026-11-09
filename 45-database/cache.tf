# THE CACHE: Amazon ElastiCache Serverless for Valkey, rebuilt every day.
#
# WHAT IT IS FOR. `catalog` caches event pages so most reads never touch PostgreSQL (cache-aside:
# look in the cache, on a miss read the database and store the result for a while), and
# `reservations` keeps a per-user sliding-window rate limiter in it (a small Lua script). Valkey is the
# open-source fork of Redis that AWS maintains; the Redis clients in the Go services work unchanged.
#
# WHY SERVERLESS. No node size to choose, it is created in a minute or two (a node-based cluster takes
# 5-10), scales on its own and bills only for data stored and compute used; the two limits below cap
# the bill. A node-based replication group would be cheaper at constant load, which a daily-rebuilt
# learning environment is not.
#
# HOW SERVICES SIGN IN: IAM, like the database. Each service has its OWN cache user, an access string
# that says what that user may do, and an IAM role that may `elasticache:Connect` as that user:
#   catalog       may use only keys that start with `catalog:`
#   reservations  may use only keys that start with `rl:`
# Both are limited to normal commands (`-@dangerous` removes FLUSHALL, KEYS, CONFIG, DEBUG and the
# like; `+client|setinfo` is added back because the Go client announces itself with it). A user with
# the same name must exist for IAM auth: the user id and user name are identical, and that name is what
# the service reads as REDIS_USER. The mandatory `default` user is switched OFF (no password, no
# commands): nobody can use the cache without being one of the two named users.
# Connections are always encrypted (TLS) on serverless caches.
#
# Related files: network.tf (who can reach it), config.tf (address, cache name and user names),
# 50-workloads (the elasticache:Connect permission per service).

locals {
  cache_users = {
    catalog      = "~catalog:*"
    reservations = "~rl:*"
  }
}

resource "aws_elasticache_user" "default_off" {
  user_id       = "${local.name_prefix}-default-off"
  user_name     = "default"
  engine        = "valkey"
  access_string = "off ~* -@all"

  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user" "app" {
  for_each = local.cache_users

  user_id       = "${local.name_prefix}-${each.key}"
  user_name     = "${local.name_prefix}-${each.key}"
  engine        = "valkey"
  access_string = "on ${each.value} +@all -@dangerous +client|setinfo"

  authentication_mode {
    type = "iam"
  }
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = local.name_prefix
  engine        = "valkey"
  user_ids      = concat([aws_elasticache_user.default_off.user_id], [for u in aws_elasticache_user.app : u.user_id])
}

resource "aws_elasticache_serverless_cache" "this" {
  name                 = local.name_prefix
  engine               = "valkey"
  major_engine_version = "8"
  description          = "Gatepass ${var.environment}: catalog cache and reservations rate limiter"

  kms_key_id         = data.aws_kms_alias.env.target_key_arn
  security_group_ids = [aws_security_group.cache.id]
  subnet_ids         = data.aws_subnets.data.ids
  user_group_id      = aws_elasticache_user_group.this.user_group_id

  cache_usage_limits {
    data_storage {
      maximum = var.cache_max_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.cache_max_ecpu_per_second
    }
  }
}
