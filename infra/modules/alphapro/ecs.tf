###############################################################################
# Cluster + logs
###############################################################################

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.default_tags
}

resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = merge(local.default_tags, { Name = local.name_prefix })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

###############################################################################
# Web / API task + service
###############################################################################

resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name_prefix}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Keep old revisions registered instead of deregistering them on replacement.
  # Task definitions are free and revisions are immutable, so retaining them
  # costs nothing and buys an instant rollback: point the service at revision
  # N-1 in the console and it redeploys the previous container config.
  skip_destroy       = true
  cpu                = var.task_cpu
  memory             = var.task_memory
  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  # Must match how var.container_image was built — see the variable's
  # description. Fargate defaults to X86_64 when this block is omitted, which
  # silently breaks an ARM64 image at task startup.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.container_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "web"
      image     = var.container_image
      essential = true
      portMappings = [
        { containerPort = var.web_port, hostPort = var.web_port, protocol = "tcp" }
      ]
      command = [
        "sh", "-c",
        # `exec` replaces the shell (PID 1) with uvicorn instead of running it
        # as a child, so ECS/Docker's SIGTERM on task stop reaches uvicorn
        # directly and it can drain in-flight requests, instead of the signal
        # being swallowed by the shell and every stop waiting out the full
        # stopTimeout before a hard SIGKILL. `uv run` itself execs into its
        # target process on Unix, so this chains cleanly through to uvicorn.
        "echo '>>> Running alembic migrations...' && uv run alembic upgrade head && echo '>>> Migrations complete. Starting uvicorn server...' && exec uv run uvicorn main:app --host 0.0.0.0 --port $${PORT:-8001}"
        #"echo '>>>Starting uvicorn server....' && exec uv run uvicorn main:app --host 0.0.0.0 --port $${PORT:-8001}"
      ]
      environment = concat([
        { name = "AWS_REGION", value = var.aws_region },
        { name = "REDIS_URL", value = local.cache_url },
        { name = "DOCS_ENABLED", value = tostring(var.docs_enabled) },
        { name = "CELERY_BROKER_URL", value = local.broker_url },
        { name = "DB_CONNECTION", value = "postgresql" },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "INFRA_RELEASE_VERSION", value = var.infra_release_version },
        { name = "PORT", value = tostring(var.web_port) },
        { name = "S3_BUCKET", value = aws_s3_bucket.assets.id },
        ],
        # Application-level settings from var.web_env, sorted for a stable diff.
        [for k in sort(keys(var.web_env)) : { name = k, value = var.web_env[k] }],
        local.celery_queue_env
      )
      secrets = concat([
        { name = "DB_HOST", valueFrom = "${local.database_secret_arn}:host::" },
        { name = "DB_DATABASE", valueFrom = "${local.database_secret_arn}:dbname::" },
        { name = "DOCS_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:docs_password::" },
        { name = "DOCS_USERNAME", valueFrom = "${aws_secretsmanager_secret.app.arn}:docs_username::" },
        # Signs JWTs — a credential, so it is fetched at task start rather than
        # baked into the task definition where DescribeTaskDefinition would
        # expose it.
        { name = "SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:secret_key::" },
        { name = "DB_PASSWORD", valueFrom = "${local.database_secret_arn}:password::" },
        { name = "DB_PORT", valueFrom = "${local.database_secret_arn}:port::" },
        { name = "DB_USERNAME", valueFrom = "${local.database_secret_arn}:username::" },
        ],
        local.mongodb_secret
      )
      # Runs INSIDE the container, which is what fills the Health status column
      # in the console — without it ECS reports UNKNOWN. Separate from, and
      # complementary to, the ALB target group check: that one proves the task
      # is reachable from outside, this one proves the process is still
      # answering. A hung worker thread can pass one and fail the other.
      #
      # Python rather than curl deliberately: the image certainly has Python
      # (it runs uvicorn through it), while slim bases usually ship no curl —
      # and a health check command that is missing fails every task.
      # urlopen raises on any non-2xx, so no explicit status comparison.
      #
      # startPeriod covers `alembic upgrade head` running before uvicorn binds
      # the port; failures inside it do not count toward retries.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://localhost:${var.web_port}${var.health_check_path}',timeout=3)\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "web"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "web" {
  name            = "${local.name_prefix}-web"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.web_desired_count

  # Capacity comes from the strategy, not launch_type — the two are mutually
  # exclusive. An empty list falls back to the cluster's default strategy.
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
  health_check_grace_period_seconds  = var.web_health_check_grace_period

  # Private subnet, no public IP: outbound traffic goes out through the NAT
  # Gateway (a stable, whitelistable IP), not an ephemeral per-task public IP.
  # Inbound traffic still arrives fine — the ALB reaches task ENIs directly
  # via the VPC's local route, regardless of which subnet tier they're in.
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = var.web_port
  }

  # The capacity providers must be attached to the cluster before a service can
  # name one in its strategy; the cluster id reference alone doesn't imply it.
  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.this,
    # The task definition references the secret's ARN, which exists the moment
    # the secret container is created — but a container with no version has no
    # AWSCURRENT label, and the agent fails the task before it starts:
    #   ResourceNotFoundException: can't find the specified secret value for
    #   staging label: AWSCURRENT
    # The database version's payload is built from the RDS address, so it lands
    # 10-20 minutes after the secret itself. Without this the service is created
    # into that gap and crash-loops while Terraform reports success.
    aws_secretsmanager_secret_version.database,
    aws_secretsmanager_secret_version.app,
  ]

  tags = local.default_tags

  # Application Auto Scaling (below) owns the live desired_count once the
  # service exists — it calls UpdateService directly, outside Terraform. On
  # create, var.web_desired_count still seeds the starting count. Without
  # this, every unrelated apply (e.g. a new container_image tag) would read
  # back whatever the autoscaler set and reconcile it down to
  # var.web_desired_count, killing tasks mid-scale-out.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Consumer tasks + services (one per store x queue type)
###############################################################################

resource "aws_ecs_task_definition" "consumer" {
  for_each = local.active_consumers

  family                   = "${local.name_prefix}-${each.value.store_id}-consumer"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Same as the web task — retain old revisions for rollback. See above.
  skip_destroy       = true
  cpu                = var.task_cpu
  memory             = var.task_memory
  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  # Same image, same architecture as the web task — see container_cpu_architecture.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.container_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "${each.value.store_id}-consumer"
      image     = var.container_image
      essential = true
      command = [
        "sh", "-c",
        "echo '>>> Starting consumer for store ${each.value.store_id}...' && exec uv run python -m ${var.consumer_module}"
      ]
      environment = concat([
        { name = "APP_URL", value = each.value.app_url },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "REDIS_URL", value = local.cache_url },
        { name = "CELERY_BROKER_URL", value = local.broker_url },
        { name = "DB_CONNECTION", value = "postgresql" },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "INFRA_RELEASE_VERSION", value = var.infra_release_version },
        # JSON array, not a bare URL. The name is plural and the field is typed
        # as a collection in the application's pydantic Settings, so
        # pydantic-settings json.loads() it — a plain URL fails at "Expecting
        # value: line 1 column 1" before the consumer starts. Same shape as
        # CELERY_SQS_QUEUE_URLS.
        { name = "SHOPIFY_SQS_QUEUE_URLS", value = jsonencode([aws_sqs_queue.main[each.key].url]) },
        { name = "SHOPIFY_SQS_STRICT_HMAC", value = var.shopify_sqs_strict_hmac },
        { name = "STORE_ID", value = each.value.store_id },
        { name = "STORE_NAME", value = each.value.store_name },
        { name = "S3_BUCKET", value = aws_s3_bucket.assets.id },
        ],
        local.celery_queue_env
      )
      # Exactly the same keys the web task reads, from the same secret.
      secrets = concat([
        { name = "DB_HOST", valueFrom = "${local.database_secret_arn}:host::" },
        { name = "DB_DATABASE", valueFrom = "${local.database_secret_arn}:dbname::" },
        { name = "DB_PASSWORD", valueFrom = "${local.database_secret_arn}:password::" },
        { name = "DB_PORT", valueFrom = "${local.database_secret_arn}:port::" },
        { name = "DB_USERNAME", valueFrom = "${local.database_secret_arn}:username::" },
        ],
        local.mongodb_secret
      )
      # There is no HTTP endpoint to probe here — a consumer is an SQS poller —
      # so this verifies PID 1 is still the consumer process rather than that
      # it is doing useful work. `exec` in the command above makes python PID 1,
      # so this catches a process that died without the container exiting.
      #
      # Be clear about the limit: it does NOT detect a consumer that is alive
      # but stuck, which is the failure that actually costs you. The queue-depth
      # and DLQ alarms are what catch that. This mainly replaces UNKNOWN with a
      # real status in the console.
      #
      # Upgrade path, if it matters later: have the consumer touch a file each
      # poll and check its mtime here — then "alive" means "still polling"
      # rather than "still loaded".
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import sys;sys.exit(0 if '${var.consumer_module}' in open('/proc/1/cmdline').read() else 1)\""]
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
          "awslogs-stream-prefix" = "${each.value.store_id}-consumer"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "consumer" {
  for_each = local.active_consumers

  name            = "${local.name_prefix}-${each.value.store_id}-consumer"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.consumer[each.key].arn
  desired_count   = var.consumer_desired_count

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

  # No health_check_grace_period_seconds — only valid on load-balanced services.

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  # Secret versions for the same reason as aws_ecs_service.web — the consumers
  # pull the same six database keys, so they fail identically against a secret
  # that exists but holds no value yet.
  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_secretsmanager_secret_version.database,
  ]

  tags = local.default_tags

  # Same reasoning as aws_ecs_service.web's lifecycle block: Application Auto
  # Scaling owns the live desired_count for each of these 12 services once
  # they exist. Without this, any deploy would fight the autoscaler and snap
  # every consumer's task count back to var.consumer_desired_count.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Application Auto Scaling (target tracking on CPU)
###############################################################################

resource "aws_appautoscaling_target" "web" {
  max_capacity       = var.web_max_capacity
  min_capacity       = var.web_min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.web.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "web_cpu" {
  name               = "${local.name_prefix}-web-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.web.resource_id
  scalable_dimension = aws_appautoscaling_target.web.scalable_dimension
  service_namespace  = aws_appautoscaling_target.web.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

resource "aws_appautoscaling_target" "consumer" {
  for_each = local.active_consumers

  max_capacity       = var.consumer_max_capacity
  min_capacity       = var.consumer_min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.consumer[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "consumer_cpu" {
  for_each = local.active_consumers

  name               = "${local.name_prefix}-${each.value.store_id}-consumer-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.consumer[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.consumer[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.consumer[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}
