###############################################################################
# Celery worker — drains the Celery broker queue.
#
# Distinct from the per-store workers in workers.tf. Those are finite CLI jobs
# (`shopify sync ...`) that run once and exit; this is a long-lived process that
# blocks on the broker and never finishes on its own.
#
# Tied to enable_celery_queue rather than its own switch: a Celery worker with
# no queue to drain is not a useful thing to leave running. Pause it by setting
# celery_worker_desired_count to 0, which keeps the service and its task
# definition in place.
#
# No autoscaling, matching the per-store workers. Celery's own concurrency
# setting controls how much a single task processes in parallel, and on a FIFO
# broker queue throughput is bounded by the number of distinct message groups
# the application sends — extra tasks past that point idle rather than help.
###############################################################################

resource "aws_ecs_task_definition" "celery_worker" {
  count = var.enable_celery_queue ? 1 : 0

  family                   = "${local.name_prefix}-celery-worker"
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
      name      = "celery-worker"
      image     = var.container_image
      essential = true

      # `exec` so celery replaces the shell as PID 1 and receives SIGTERM
      # directly on task stop — that is what lets it finish the task in flight
      # and stop accepting new ones, instead of the signal being swallowed and
      # the task hard-killed after stopTimeout.
      command = [
        "sh", "-c",
        "echo '>>> Starting Celery worker...' && exec uv run celery -A app.core.celery worker --loglevel=info"
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

      # `celery inspect ping` would prove the worker is actually responsive, but
      # it needs a broker round-trip on every check and fails during a long
      # task. This settles for proving PID 1 is still the worker process — the
      # queue-depth and DLQ alarms are what catch a worker that is alive but
      # not draining.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import sys;sys.exit(0 if 'celery' in open('/proc/1/cmdline').read() else 1)\""]
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
          "awslogs-stream-prefix" = "celery-worker"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "celery_worker" {
  count = var.enable_celery_queue ? 1 : 0

  name            = "${local.name_prefix}-celery-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.celery_worker[0].arn
  desired_count   = var.celery_worker_desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  dynamic "deployment_circuit_breaker" {
    for_each = var.enable_deployment_circuit_breaker ? [1] : []
    content {
      enable   = true
      rollback = true
    }
  }

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent

  # No load_balancer and no health_check_grace_period — nothing routes to it.

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  # The secret must hold a value before a task can start; see
  # aws_ecs_service.web for the failure this prevents.
  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_secretsmanager_secret_version.database,
  ]

  tags = local.default_tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Celery beat — the scheduler that publishes periodic tasks.
#
# Exactly one task, always. Two beats mean every scheduled job fires twice.
# RedBeat (CELERY_BEAT_SCHEDULER) keeps the schedule in Redis behind a lock, so
# a second instance cannot double-fire — but it would still sit there holding a
# task slot, so the deployment settings below enforce one anyway.
#
# Deliberately NOT the module's usual 100/200 rolling deployment: that briefly
# runs two tasks, which is exactly what a singleton must not do. 0/100 stops
# the old task before starting the new one, trading a short scheduling gap for
# the guarantee. Beat catches up on its next tick, so the gap costs nothing.
#
# No autoscaling for the same reason, and no load balancer — nothing routes to
# a scheduler.
###############################################################################

resource "aws_ecs_task_definition" "celery_beat" {
  count = var.enable_celery_queue ? 1 : 0

  family                   = "${local.name_prefix}-celery-beat"
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
      name      = "celery-beat"
      image     = var.container_image
      essential = true

      # No --scheduler flag: CELERY_BEAT_SCHEDULER carries it, so the scheduler
      # is configured in one place rather than two that can disagree.
      command = [
        "sh", "-c",
        "echo '>>> Starting Celery beat...' && exec uv run celery -A app.core.celery beat --loglevel=info"
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

      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import sys;sys.exit(0 if 'beat' in open('/proc/1/cmdline').read() else 1)\""]
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
          "awslogs-stream-prefix" = "celery-beat"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "celery_beat" {
  count = var.enable_celery_queue ? 1 : 0

  name            = "${local.name_prefix}-celery-beat"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.celery_beat[0].arn
  desired_count   = var.celery_beat_desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  dynamic "deployment_circuit_breaker" {
    for_each = var.enable_deployment_circuit_breaker ? [1] : []
    content {
      enable   = true
      rollback = true
    }
  }

  # Singleton: stop the old task before starting the new one.
  deployment_maximum_percent         = 100
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
