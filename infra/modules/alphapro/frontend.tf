###############################################################################
# Frontend SPA — shares the backend's ALB, added purely as listener rules.
#
#   frontend_host_header (e.g. dev.alfapro.ai) -> frontend target group
#   every other host                           -> backend, via the listener's
#                                                 UNCHANGED default action
#
# Additive by design: the default action is never touched, so the backend's
# routing is exactly what it was before this file existed. Adding, changing or
# removing the frontend cannot affect the API.
#
# One ALB, one certificate, one DNS target, no duplicated security group or
# subnet wiring. Rules are evaluated by priority; anything matching none of
# them falls through to the default.
###############################################################################

resource "aws_lb_target_group" "frontend" {
  count = local.enable_frontend ? 1 : 0

  name        = "${local.name_prefix}-fe-tg"
  port        = var.frontend_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = var.frontend_health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = var.health_check_timeout
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-fe-tg" })
}

###############################################################################
# Listener rules — the frontend's only claim on the ALB, on 80 and 443.
#
# The HTTP rule is skipped when port 80 only redirects to 443: a redirect is
# the listener's default action and fires before rules are evaluated, so a
# forwarding rule there would be dead config.
###############################################################################

resource "aws_lb_listener_rule" "frontend_https" {
  count = local.enable_frontend && local.enable_https ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 100

  condition {
    host_header {
      values = [var.frontend_host_header]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend[0].arn
  }

  tags = local.default_tags
}

resource "aws_lb_listener_rule" "frontend_http" {
  count = local.enable_frontend && !local.redirect_http_to_https ? 1 : 0

  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    host_header {
      values = [var.frontend_host_header]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend[0].arn
  }

  tags = local.default_tags
}

###############################################################################
# Task definition + service
###############################################################################

resource "aws_ecs_task_definition" "frontend" {
  count = local.enable_frontend ? 1 : 0

  family                   = "${local.name_prefix}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Retain old revisions for rollback, same as the backend tasks.
  skip_destroy       = true
  cpu                = var.task_cpu
  memory             = var.task_memory
  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  # Must match how the FRONTEND image was built, which is not necessarily how
  # the backend was — see var.frontend_cpu_architecture.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = local.frontend_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = var.frontend_container_image
      essential = true
      portMappings = [
        { containerPort = var.frontend_port, hostPort = var.frontend_port, protocol = "tcp" }
      ]

      # No command override: the image's own entrypoint starts nginx.
      #
      # Sorted for a stable diff — an unsorted map would reorder between plans
      # and show phantom task-definition changes.
      environment = [
        for k in sort(keys(var.frontend_env)) : {
          name  = k
          value = var.frontend_env[k]
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "frontend"
        }
      }
    }
  ])

  tags = local.default_tags
}

resource "aws_ecs_service" "frontend" {
  count = local.enable_frontend ? 1 : 0

  name            = "${local.name_prefix}-frontend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.frontend[0].arn
  desired_count   = var.frontend_desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  health_check_grace_period_seconds  = var.web_health_check_grace_period

  # Private subnets, no public IP — the ALB reaches task ENIs over the VPC's
  # local route, and outbound traffic egresses through the NAT Gateway.
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend[0].arn
    container_name   = "frontend"
    container_port   = var.frontend_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.this,
  ]

  tags = local.default_tags

  # Application Auto Scaling owns the live count once the service exists — see
  # the same block on aws_ecs_service.web.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Autoscaling
###############################################################################

resource "aws_appautoscaling_target" "frontend" {
  count = local.enable_frontend ? 1 : 0

  max_capacity       = var.frontend_max_capacity
  min_capacity       = var.frontend_min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.frontend[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "frontend_cpu" {
  count = local.enable_frontend ? 1 : 0

  name               = "${local.name_prefix}-frontend-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.frontend[0].resource_id
  scalable_dimension = aws_appautoscaling_target.frontend[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.frontend[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}
