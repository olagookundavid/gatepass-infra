# THE TWO DYNAMODB TABLES: reservations (inventory, holds) and notifications.
#
# WHY DYNAMODB HERE. Holding tickets is a "many people want the same few items at once" problem.
# DynamoDB gives single-item conditional writes and transactions with predictable latency and no
# server to size or patch: "take 2 tickets from this counter only if at least 2 are left" is one
# conditional update, and 50 simultaneous attempts against 10 tickets produce exactly 10 winners
# (the integration test of the reservations service proves it). The whole service uses ONE table
# (single-table design): items of different kinds share the table and are told apart by their key
# prefixes, so one query fetches everything about an event.
#
# KEYS AND INDEXES come from the service (gatepass-app/HANDOFF.md section 4), so they must match
# exactly:
#   reservations   PK (hash), SK (range); GSI1 on GSI1PK/GSI1SK (projection ALL) for "my holds";
#                  TTL attribute `ttl` (epoch seconds); a STREAM with old and new images.
#   notifications  PK, SK; TTL attribute `ttl` (only the event markers); no index, no stream.
#
# TTL ("time to live"): DynamoDB deletes an item some time after its `ttl` timestamp (usually
# within minutes, up to days; it is housekeeping, not a timer). Expiry of a HOLD is therefore NOT
# left to TTL: an EventBridge Scheduler one-time schedule invokes the hold-expirer Lambda at the
# exact second, and the stream trigger is only the safety net for items that TTL removed.
#
# BILLING is on demand (pay per request): at this volume it costs cents and needs no capacity
# planning. Point-in-time recovery keeps 35 days of history so a bad deploy can be undone (Phase
# 11 restores a table). Encryption uses the environment key. deletion_protection is off in dev.
#
# Related files: lambda.tf (reads the stream), iam in 50-workloads (per-service access to exactly
# these table ARNs), config.tf (publishes the names).

resource "aws_dynamodb_table" "reservations" {
  name         = "${local.name_prefix}-reservations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    projection_type = "ALL"

    key_schema {
      attribute_name = "GSI1PK"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "GSI1SK"
      key_type       = "RANGE"
    }
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = data.aws_kms_alias.env.target_key_arn
  }

  deletion_protection_enabled = false
}

resource "aws_dynamodb_table" "notifications" {
  name         = "${local.name_prefix}-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = data.aws_kms_alias.env.target_key_arn
  }

  deletion_protection_enabled = false
}
