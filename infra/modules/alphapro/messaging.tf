###############################################################################
# SQS - dead-letter queues
###############################################################################

resource "aws_sqs_queue" "dlq" {
  for_each = local.store_queues

  name                        = each.value.dlq_name
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo

  visibility_timeout_seconds = 30
  message_retention_seconds  = 1209600 # 14 days
  max_message_size           = 262144  # 256 KB

  tags = merge(local.default_tags, { Name = each.value.dlq_name })
}

###############################################################################
# SQS - main queues (with redrive to the matching DLQ)
###############################################################################

resource "aws_sqs_queue" "main" {
  for_each = local.store_queues

  name                        = each.value.queue_name
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo

  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600 # 4 days
  max_message_size           = 262144 # 256 KB

  # Long polling: consumers block instead of spinning on empty receives.
  receive_wait_time_seconds = var.sqs_receive_wait_time_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = merge(local.default_tags, { Name = each.value.queue_name })
}

# Allow the matching EventBridge rule to deliver to each main queue.
resource "aws_sqs_queue_policy" "main" {
  for_each = local.store_queues

  queue_url = aws_sqs_queue.main[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main[each.key].arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.this[each.key].arn }
        }
      }
    ]
  })
}

###############################################################################
# EventBridge - rules on the Shopify partner buses + SQS targets
###############################################################################

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.store_queues

  name           = "${local.name_prefix}-${each.value.store_id}-${each.value.queue_type}"
  event_bus_name = each.value.event_bus
  description    = "Route Shopify ${each.value.queue_type} webhooks for ${each.value.store_id}"

  event_pattern = jsonencode({
    "detail-type" = ["shopifyWebhook"]
    detail = {
      metadata = {
        "X-Shopify-Topic" = [{ prefix = each.value.topic_prefix }]
      }
    }
  })

  tags = local.default_tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.store_queues

  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = each.value.event_bus
  arn            = aws_sqs_queue.main[each.key].arn

  # FIFO queues require a message group id; standard queues must not set one.
  dynamic "sqs_target" {
    for_each = each.value.fifo ? [1] : []
    content {
      message_group_id = "${each.value.store_id}-${each.value.queue_type}"
    }
  }
}
