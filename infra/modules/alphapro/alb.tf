resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_lb_target_group" "web" {
  name        = "${local.name_prefix}-tg"
  port        = var.web_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = var.health_check_timeout
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Port 80 either bounces clients to 443 (a 301, so they cache the upgrade) or
  # serves the app directly. Redirecting needs BOTH a certificate — there must
  # be a 443 listener to land on — and the redirect switch being on; see
  # local.redirect_http_to_https.
  #
  # One block with conditional attributes rather than two mutually-exclusive
  # dynamic blocks: target_group_arn is Optional+Computed, so omitting it on
  # the redirect branch let the provider carry the previous forward value
  # forward and warn about an invalid combination. Setting it to null states
  # the intent explicitly.
  default_action {
    type             = local.redirect_http_to_https ? "redirect" : "forward"
    target_group_arn = local.redirect_http_to_https ? null : aws_lb_target_group.web.arn

    dynamic "redirect" {
      for_each = local.redirect_http_to_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = local.default_tags
}

# TLS terminates here. The target group stays HTTP on var.web_port — the hop
# from ALB to task runs inside the VPC across the local route, so uvicorn never
# needs a certificate of its own.
resource "aws_lb_listener" "https" {
  count = local.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = local.default_tags
}
