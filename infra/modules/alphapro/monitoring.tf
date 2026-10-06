resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-alarms"

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-alarms" })
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

###############################################################################
# Per-store alarms (3 each => 12 total)
###############################################################################

# DLQ has any visible messages -> something failed past the retry limit.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.store_queues

  alarm_name          = "${local.name_prefix}-${each.value.store_id}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages present in DLQ for ${each.key}"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.default_tags
}

# Same alarm for the Celery broker's DLQ. Not covered by the loop above, which
# only walks the per-store webhook queues — and an unwatched DLQ is just a
# place failures go to be forgotten.
resource "aws_cloudwatch_metric_alarm" "celery_dlq_not_empty" {
  count = var.enable_celery_queue ? 1 : 0

  alarm_name          = "${local.name_prefix}-celery-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages present in the Celery DLQ — a task exhausted its retries"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.celery_dlq[0].name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.default_tags
}

# Consumer service has no running tasks.
resource "aws_cloudwatch_metric_alarm" "no_running_tasks" {
  for_each = local.active_consumers

  alarm_name          = "${local.name_prefix}-${each.value.store_id}-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "No running tasks for ${each.key} consumer"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.consumer[each.key].name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.default_tags
}

# Main queue depth too high -> consumers falling behind.
resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  for_each = local.store_queues

  alarm_name          = "${local.name_prefix}-${each.value.store_id}-queue-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_queue_depth_threshold
  alarm_description   = "Queue depth above ${var.alarm_queue_depth_threshold} for ${each.key}"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.main[each.key].name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.default_tags
}
