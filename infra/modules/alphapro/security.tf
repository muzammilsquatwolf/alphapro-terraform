###############################################################################
# Security groups
###############################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Open unconditionally, not gated on the certificate. Carries no exposure on
  # its own: until aws_lb_listener.https exists there is nothing listening on
  # 443, so connections are simply refused. Keeping it static means adding a
  # certificate later is a listener change only, with no security group edit.
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ecs" {
  name_prefix = "${local.name_prefix}-ecs-"
  description = "Security group for ECS Fargate tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Web port from ALB"
    from_port       = var.web_port
    to_port         = var.web_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Frontend tasks share this security group but listen on their own port.
  # Only opened when a frontend exists, and still only from the ALB.
  #
  # Skipped when the two ports coincide: the rule above already covers it, and
  # sending EC2 two identical permissions fails with InvalidPermission.Duplicate.
  dynamic "ingress" {
    for_each = local.enable_frontend && var.frontend_port != var.web_port ? [1] : []
    content {
      description     = "Frontend port from ALB"
      from_port       = var.frontend_port
      to_port         = var.frontend_port
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-ecs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-db-"
  description = "Security group for RDS database"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "valkey" {
  name_prefix = "${local.name_prefix}-valkey-"
  description = "Security group for ElastiCache Valkey"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Broker port from ECS"
    from_port       = var.broker_port
    to_port         = var.broker_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  ingress {
    description     = "Cache port from ECS"
    from_port       = var.cache_port
    to_port         = var.cache_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-valkey" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "quicksight" {
  count = var.enable_quicksight_access ? 1 : 0

  name_prefix = "${local.name_prefix}-quicksight-"
  description = "Security group for QuickSight ENIs"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-quicksight" })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Database security group rules
###############################################################################

resource "aws_security_group_rule" "db_from_ecs" {
  type                     = "ingress"
  description              = "PostgreSQL from ECS tasks"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "db_public_ingress" {
  for_each = toset(var.allowed_db_cidrs)

  type              = "ingress"
  description       = "PostgreSQL from allowed public CIDR"
  from_port         = var.db_port
  to_port           = var.db_port
  protocol          = "tcp"
  security_group_id = aws_security_group.db.id
  cidr_blocks       = [each.value]
}

resource "aws_security_group_rule" "db_from_quicksight" {
  count = var.enable_quicksight_access ? 1 : 0

  type                     = "ingress"
  description              = "PostgreSQL from QuickSight"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.quicksight[0].id
}

resource "aws_security_group_rule" "quicksight_egress_to_db" {
  count = var.enable_quicksight_access ? 1 : 0

  type                     = "egress"
  description              = "QuickSight egress to PostgreSQL"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.quicksight[0].id
  source_security_group_id = aws_security_group.db.id
}
