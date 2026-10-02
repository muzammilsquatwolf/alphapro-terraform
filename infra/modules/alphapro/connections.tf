# Computed connection strings shared by the secrets payload and container env.
locals {
  # Generated password when we manage the DB; empty when reusing an existing one
  # (the existing secret already holds the real password).
  db_password = local.create_database ? one(random_password.db[*].result) : ""

  # Effective host: the supplied existing endpoint, or the created cluster's
  # WRITER endpoint. Never the reader — this host is what runs migrations and
  # every write, and a reader accepts the connection before rejecting the write.
  db_host = var.db_host != "" ? var.db_host : one(aws_rds_cluster.this[*].endpoint)
  db_port = var.db_port

  database_url = "postgresql://${var.db_username}:${local.db_password}@${local.db_host}:${local.db_port}/${var.db_name}"

  # Celery talks to SQS, not Redis. No credentials in the URL — kombu falls
  # through to boto3's default chain, which on Fargate is the task role, and
  # the region comes from the AWS_REGION the tasks already carry.
  #
  # The queue itself is named by CELERY_DEFAULT_QUEUE and reachable through
  # CELERY_SQS_QUEUE_URLS; see local.celery_queue_env.
  broker_url = "sqs://"

  # REDIS_URL only — the application's own Redis client, not Celery. No
  # ssl_cert_reqs: that parameter was Celery's requirement, and Celery no
  # longer speaks Redis.
  cache_url = "rediss://${aws_elasticache_replication_group.cache.primary_endpoint_address}:${var.cache_port}/0"

  # ARN of the database secret, whether created here or pre-existing.
  database_secret_arn = local.create_database ? one(aws_secretsmanager_secret.database[*].arn) : data.aws_secretsmanager_secret.database[0].arn
}
