data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

###############################################################################
# ECS task execution role (pull image, write logs, read secrets)
###############################################################################

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.iam_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_secrets" {
  name        = "${local.iam_prefix}-ecs-secrets"
  description = "Allow ECS execution role to read application secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          local.database_secret_arn,
          aws_secretsmanager_secret.app.arn,
        ]
      }
    ]
  })

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_secrets" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = aws_iam_policy.ecs_secrets.arn
}

###############################################################################
# ECS task (application) role - SQS, EventBridge, logs
###############################################################################

resource "aws_iam_role" "ecs_task" {
  name               = "${local.iam_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = local.default_tags
}

resource "aws_iam_policy" "ecs_task" {
  name        = "${local.iam_prefix}-ecs-task"
  description = "Application permissions for ECS tasks (SQS, EventBridge, logs)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = "arn:aws:sqs:*:*:${local.name_prefix}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:aws:events:*:*:event-bus/${local.name_prefix}-*"
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        # Log streams live "under" the log group ARN; :* covers all streams
        # within it. Scoped to this module's own log group, not every log
        # group in the account.
        Resource = "${aws_cloudwatch_log_group.ecs.arn}:*"
      },
    ]
  })

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task.arn
}

###############################################################################
# ECS task role - S3 assets bucket (read/write/delete)
###############################################################################

resource "aws_iam_policy" "ecs_s3_assets" {
  name        = "${local.iam_prefix}-ecs-s3-assets"
  description = "Allow ECS tasks to read, write, and delete objects in the assets bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.assets.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.assets.arn
      },
    ]
  })

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_s3_assets" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_s3_assets.arn
}
