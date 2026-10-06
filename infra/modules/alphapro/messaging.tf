###############################################################################
# SQS - one queue + DLQ per store
#
# All FIFO now, products included. Products does not need ordering, but it
# shares a queue with orders and inventory, which do — and a queue is FIFO or
# it is not. The cost is FIFO's 300 TPS ceiling without batching, comfortably
# above Shopify webhook volume for a single store.
###############################################################################

resource "aws_sqs_queue" "dlq" {
  for_each = local.store_queues

  name                        = each.value.dlq_name
  fifo_queue                  = true
  content_based_deduplication = true

  visibility_timeout_seconds = 30
  message_retention_seconds  = 1209600 # 14 days
  max_message_size           = 262144  # 256 KB

  tags = merge(local.default_tags, { Name = each.value.dlq_name })
}

resource "aws_sqs_queue" "main" {
  for_each = local.store_queues

  name                        = each.value.queue_name
  fifo_queue                  = true
  content_based_deduplication = true

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

# Admit exactly the three rules that feed this store's queue — not every rule
# in the account, and not the other stores' rules.
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
          ArnEquals = { "aws:SourceArn" = local.store_rule_arns[each.key] }
        }
      }
    ]
  })
}

###############################################################################
# EventBridge - one rule per (store, topic), all targeting the store's queue
###############################################################################

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.store_rules

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
  for_each = local.store_rules

  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = each.value.event_bus
  arn            = aws_sqs_queue.main[each.value.store_id].arn

  # The group id is the whole mechanism: it keeps each topic ordered within
  # itself while letting the three run in parallel inside one queue.
  sqs_target {
    message_group_id = each.value.message_group_id
  }
}

###############################################################################
# Celery broker queue + its dead-letter queue
#
# Separate from the per-store webhook queues: those are filled by EventBridge
# and drained by the consumers, while this one carries the application's own
# background tasks.
#
# FIFO, matching the orders and inventory queues. Two things follow: the name
# MUST end in .fifo (SQS rejects it otherwise, and kombu keys its FIFO handling
# off that suffix), and ordering is preserved per message group — so
# concurrency is bounded by how many distinct group ids the application sends,
# not by how many workers run. A DLQ matters more here than on a standard
# queue: a message that keeps failing blocks its whole group behind it, so
# moving it aside is what lets the rest of that group drain.
#
# content_based_deduplication means producers need not supply a dedup id, at
# the cost of SQS treating two identical payloads within 5 minutes as one.
# Same trade-off the store queues already make.
#
# maxReceiveCount is 5 rather than the store queues' 3: Celery retries a task
# in-process before the message ever returns to the queue, so a redelivery here
# represents a whole exhausted retry cycle, not a single failure.
###############################################################################

resource "aws_sqs_queue" "celery_dlq" {
  count = var.enable_celery_queue ? 1 : 0

  name                        = "${local.name_prefix}-celery-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true

  # Longer than the main queue: a dead letter is something a human needs to
  # look at, and 4 days is easy to sleep through over a weekend.
  message_retention_seconds = 1209600 # 14 days

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-celery-dlq.fifo" })
}

resource "aws_sqs_queue" "celery" {
  count = var.enable_celery_queue ? 1 : 0

  name                        = "${local.name_prefix}-celery.fifo"
  fifo_queue                  = true
  content_based_deduplication = true

  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600 # 4 days
  max_message_size           = 262144 # 256 KB
  receive_wait_time_seconds  = var.sqs_receive_wait_time_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.celery_dlq[0].arn
    maxReceiveCount     = 5
  })

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-celery.fifo" })
}
