###############################################################################
# Shell — a task that exists only to be exec'd into.
#
# One service carries enable_execute_command rather than all seven. A shell in
# a task can read every secret that task was given and act with its role, so
# opening every service to exec grants that over the web app, the consumers and
# the Celery worker at once. Here it is one task, with the same image and the
# same environment, so a command behaves identically — and if the capability is
# ever abused or mis-granted, the blast radius is a container doing nothing.
#
# The container sleeps. `tail -f /dev/null` rather than `sleep infinity`:
# busybox sleep rejects a non-numeric argument, and the image's base is not
# this module's business.
###############################################################################

resource "aws_ecs_task_definition" "shell" {
  count = var.enable_ecs_exec ? 1 : 0

  family                   = "${local.name_prefix}-shell"
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
      name      = "shell"
      image     = var.container_image
      essential = true

      command = ["sh", "-c", "echo '>>> Shell task ready — exec into it.' && exec tail -f /dev/null"]

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
          "awslogs-stream-prefix" = "shell"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "shell" {
  count = var.enable_ecs_exec ? 1 : 0

  name            = "${local.name_prefix}-shell"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.shell[0].arn
  desired_count   = 1

  # The only service in the stack that allows it.
  enable_execute_command = true

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

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

  # Scale to 0 when nobody needs a shell; Terraform will not put it back.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Resource events worker.
#
# Not in the per-store workers map, because the command takes no --channel-id:
# it is one process for the whole environment, not one per store. Putting it
# there would mean picking a store arbitrarily and injecting a STORE_ID the
# process has no use for.
#
# `work` reads as a long-running loop rather than a job that finishes, so a
# service is the right shape — if it does exit, ECS restarts it, which is the
# behaviour you want for a worker and not for a backfill.
###############################################################################

resource "aws_ecs_task_definition" "resource_events" {
  family                   = "${local.name_prefix}-resource-events"
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
      name      = "resource-events"
      image     = var.container_image
      essential = true

      command = [
        "sh", "-c",
        "echo '>>> Starting resource-events worker...' && exec uv run python -m app.cli.main resource-events work"
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

      # Proves PID 1 is still the CLI process, not that it is making progress.
      # Same caveat as the consumers: a worker that is alive but stuck passes
      # this, and the queue-depth alarms are what catch that.
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
          "awslogs-stream-prefix" = "resource-events"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "resource_events" {
  name            = "${local.name_prefix}-resource-events"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.resource_events.arn
  desired_count   = var.resource_events_desired_count

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
