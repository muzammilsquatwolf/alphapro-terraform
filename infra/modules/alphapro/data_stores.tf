###############################################################################
# Aurora PostgreSQL
#
# A cluster, not a standalone instance. Three consequences worth knowing:
#
#   - Storage is Aurora's to manage. It grows on its own up to 128 TiB, so
#     db_allocated_storage, db_max_allocated_storage and storage_type no longer
#     apply. Billing moves from "the volume you provisioned" to storage used
#     plus I/O requests.
#   - db_multi_az stops meaning "attach a standby" and starts meaning "run a
#     second instance". Aurora replicas read the same shared storage rather
#     than streaming from a primary, so the second one serves reads as well as
#     standing by — failover is a promotion, not a DNS swap onto a cold copy.
#   - Aurora tracks PostgreSQL major versions behind RDS. db_engine_version has
#     to be a major Aurora actually offers, which is not always the newest one
#     RDS has.
###############################################################################

resource "aws_db_subnet_group" "this" {
  count = local.create_database ? 1 : 0

  name = "${local.name_prefix}-db"
  # A privately-routed subnet (NAT-only route table) can't actually serve a
  # publicly_accessible instance — inbound internet traffic has no IGW path
  # to it, so the public endpoint would resolve but never connect. Use public
  # subnets when public access is wanted; the security group's CIDR allowlist
  # (aws_security_group_rule.db_public_ingress), not subnet placement, is what
  # actually restricts who can reach it.
  subnet_ids = var.db_publicly_accessible ? aws_subnet.public[*].id : aws_subnet.private[*].id

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-db" })
}

resource "aws_rds_cluster_parameter_group" "this" {
  count = local.create_database ? 1 : 0

  # name_prefix rather than name. create_before_destroy below builds the
  # replacement before dropping the old group, and two parameter groups cannot
  # share a name — a fixed name deadlocks on DBParameterGroupAlreadyExists the
  # first time anything forces a replacement, which is exactly how the previous
  # standalone-instance group got stuck. The generated suffix keeps them apart.
  name_prefix = "${local.name_prefix}-aurora-pg${local.db_engine_major}-"
  family      = "aurora-postgresql${local.db_engine_major}"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "pg_stat_statements.track"
    value = "all"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  # PostgreSQL 18 turned log_connections from a boolean into a list of the
  # connection aspects to log (receipt / authentication / authorization /
  # setup_durations / all), and rejects the old "1" outright:
  #   InvalidParameterValue: Invalid parameter value: 1 for: log_connections
  # "all" is what the old boolean true meant. log_disconnections is untouched
  # by that change and stays boolean on every major.
  parameter {
    name  = "log_connections"
    value = tonumber(local.db_engine_major) >= 18 ? "all" : "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-aurora-pg${local.db_engine_major}" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "this" {
  count = local.create_database ? 1 : 0

  cluster_identifier = local.name_prefix
  engine             = "aurora-postgresql"
  engine_version     = var.db_engine_version

  database_name   = var.db_name
  master_username = var.db_username
  master_password = random_password.db[0].result
  port            = var.db_port

  db_subnet_group_name            = aws_db_subnet_group.this[0].name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].name

  # Aurora encrypts at the cluster, not per volume, and it cannot be switched on
  # afterwards — the only route is restoring a snapshot into a new encrypted
  # cluster. Getting it right at creation is the whole opportunity.
  storage_encrypted = true

  backup_retention_period   = var.db_backup_retention_period
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name_prefix}-final"
  deletion_protection       = var.db_deletion_protection

  # Ships the Postgres log to CloudWatch, which is what makes the parameter
  # group's slow-query and connection logging readable at all.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(local.default_tags, { Name = local.name_prefix })

  # Once this cluster exists, no plan may destroy or replace it — not a config
  # change, not `terraform destroy`, not flipping db_host back to reuse-mode
  # later. deletion_protection stops the AWS API call; this stops Terraform
  # from ever issuing it. To actually decommission this database, remove this
  # block deliberately first.
  lifecycle {
    prevent_destroy = true
  }
}

# The cluster is storage and endpoints; these are what actually serve queries.
# One is a working database, two is the first count that survives losing an AZ
# — which is what db_multi_az buys here. Both read the same shared storage, so
# the second is compute only: no replication lag to watch, and it answers reads
# through the reader endpoint instead of idling like an RDS standby.
#
# Deliberately not prevent_destroy: resizing the fleet or changing instance
# class is ordinary maintenance. The cluster below them holds the data and the
# protection.
resource "aws_rds_cluster_instance" "this" {
  count = local.create_database ? (var.db_multi_az ? 2 : 1) : 0

  identifier         = "${local.name_prefix}-${count.index}"
  cluster_identifier = aws_rds_cluster.this[0].id
  instance_class     = var.db_instance_class

  # Read off the cluster rather than the variables, so an instance can never
  # drift onto a different engine or version than the cluster it belongs to.
  engine         = aws_rds_cluster.this[0].engine
  engine_version = aws_rds_cluster.this[0].engine_version

  db_subnet_group_name = aws_db_subnet_group.this[0].name
  publicly_accessible  = var.db_publicly_accessible

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-${count.index}" })
}

###############################################################################
# ElastiCache Valkey - broker (Celery) and application cache
###############################################################################

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-valkey"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-valkey" })
}

resource "aws_elasticache_replication_group" "broker" {
  replication_group_id = "${local.name_prefix}-valkey"
  description          = "${local.name_prefix} Valkey - Celery broker / result backend"

  engine         = "valkey"
  engine_version = var.valkey_engine_version
  node_type      = var.valkey_node_type
  port           = var.broker_port

  num_cache_clusters         = var.valkey_num_cache_clusters
  automatic_failover_enabled = var.valkey_automatic_failover

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.valkey.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-valkey" })
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id = "${local.name_prefix}-valkey-cache"
  description          = "${local.name_prefix} Valkey - application cache"

  engine         = "valkey"
  engine_version = var.valkey_engine_version
  node_type      = var.valkey_node_type
  port           = var.cache_port

  num_cache_clusters         = var.valkey_num_cache_clusters
  automatic_failover_enabled = var.valkey_automatic_failover

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.valkey.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-valkey-cache" })
}
