###############################################################################
# Per-store workers — Shopify CLI runs, one ECS service per enabled store.
#
# Driven entirely from the workers map in var.stores, so switching one on
# means editing stores.auto.tfvars and nothing else:
#
#   uae = {
#     store_name = "AlphaPro UAE"
#     event_bus  = "..."
#     workers = {
#       orders    = { args = ["shopify", "sync", "orders",    "--channel-id=1", ...] }
#       products  = { args = ["shopify", "sync", "products",  "--channel-id=1", ...] }
#       inventory = { enabled = false, args = [...] }
#     }
#   }
#
# args is the full argument list after `python -m app.cli.main`, so each store
# can pass different channel/app ids, limits and flags without this module
# knowing what any of them mean.
#
# No autoscaling: a worker's throughput is bounded by Shopify's API, not by
# task CPU, so extra tasks would duplicate work rather than divide it.
###############################################################################

resource "aws_ecs_task_definition" "worker" {
  for_each = local.store_workers

  family                   = "${local.name_prefix}-${each.key}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Retain old revisions for rollback, same as every other task here.
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
      name      = "${each.key}-worker"
      image     = var.container_image
      essential = true

      # `exec` so the CLI replaces the shell as PID 1 and receives SIGTERM
      # directly on task stop, rather than the signal being swallowed.
      command = [
        "sh", "-c",
        "echo '>>> Starting ${each.value.worker_name} worker for store ${each.value.store_id}...' && exec python -m app.cli.main ${join(" ", each.value.args)}"
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
        { name = "STORE_ID", value = each.value.store_id },
        { name = "STORE_NAME", value = each.value.store_name },
        { name = "WORKER_NAME", value = each.value.worker_name },
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

      # Same shape and same caveat as the consumer check in ecs.tf: PID 1 is the
      # CLI process thanks to `exec`, so this proves it is loaded, not that the
      # sync is progressing. A worker is a finite job rather than a loop, so
      # expect the task to exit cleanly when it finishes — that is success, not
      # an unhealthy container.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import sys;sys.exit(0 if 'app.cli.main' in open('/proc/1/cmdline').read() else 1)\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "${each.key}-worker"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "worker" {
  for_each = local.store_workers

  name            = "${local.name_prefix}-${each.key}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker[each.key].arn
  desired_count   = var.worker_desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }


  # Abandon a deployment whose tasks keep failing to start, and return to the
  # last revision that worked. Off leaves the AWS default, which retries
  # forever.
  dynamic "deployment_circuit_breaker" {
    for_each = var.enable_deployment_circuit_breaker ? [1] : []
    content {
      enable   = true
      rollback = true
    }
  }

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent

  # No load_balancer and no health_check_grace_period — nothing routes to a
  # worker task.

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  # Same database keys as the consumers, so the same ordering requirement —
  # see aws_ecs_service.web for why the secret's ARN alone is not enough.
  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_secretsmanager_secret_version.database,
  ]

  tags = local.default_tags

  # Consistent with the other services: the running count is an operational
  # decision (scale to 0 to pause a worker), and Terraform should not reset it.
  lifecycle {
    ignore_changes = [desired_count]
  }
}
