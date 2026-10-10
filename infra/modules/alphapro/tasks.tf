###############################################################################
# One-shot tasks — registered, never served.
#
# Runs under a service, the same way the per-store workers do — which means it
# LOOPS. `sitemap generate` finishes, the container exits, ECS notices the
# service is below its desired count and starts another. Continuous
# regeneration rather than a single run.
#
# That is fine for a sitemap and wrong for a backfill, so the count is its own
# variable: set sitemap_desired_count to 0 to stop it, 1 to have it cycle. For
# a genuine run-once, set 0 and start the task definition by hand instead — it
# stays registered either way.
#
# No healthCheck: the honest answer to "is this still alive" for a job between
# runs is no, and a check would mark a successful run unhealthy moments before
# it exits.
###############################################################################

resource "aws_ecs_task_definition" "sitemap" {
  family                   = "${local.name_prefix}-sitemap"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  skip_destroy       = true
  cpu                = var.task_cpu
  memory             = var.task_memory
  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.container_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "sitemap"
      image     = var.container_image
      essential = true

      command = [
        "sh", "-c",
        "echo '>>> Generating sitemap...' && exec uv run python -m app.cli.main sitemap generate"
      ]

      environment = concat([
        { name = "APP_URL", value = var.app_url },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "REDIS_URL", value = local.cache_url },
        { name = "CELERY_BROKER_URL", value = local.broker_url },
        { name = "CELERY_BEAT_SCHEDULER", value = "redbeat.RedBeatScheduler" },
        { name = "DB_CONNECTION", value = "postgresql" },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "INFRA_RELEASE_VERSION", value = var.infra_release_version },
        { name = "S3_BUCKET", value = aws_s3_bucket.assets.id },
        ],
        local.celery_queue_env,
        local.public_assets_env
      )

      secrets = concat([
        { name = "DB_HOST", valueFrom = "${local.database_secret_arn}:host::" },
        { name = "DB_DATABASE", valueFrom = "${local.database_secret_arn}:dbname::" },
        { name = "DB_PASSWORD", valueFrom = "${local.database_secret_arn}:password::" },
        { name = "DB_PORT", valueFrom = "${local.database_secret_arn}:port::" },
        { name = "DB_USERNAME", valueFrom = "${local.database_secret_arn}:username::" },
        ],
        local.mongodb_secret
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "sitemap"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "sitemap" {
  name            = "${local.name_prefix}-sitemap"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.sitemap.arn
  desired_count   = var.sitemap_desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  # No circuit breaker. It judges a deployment by whether tasks stay running,
  # and this one is meant to exit — every successful run would read as a failed
  # deployment and trigger a rollback.

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = 0

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_secretsmanager_secret_version.database,
  ]

  tags = local.default_tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}
