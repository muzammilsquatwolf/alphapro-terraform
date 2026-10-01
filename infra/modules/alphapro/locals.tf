locals {
  name_prefix = "${var.project}-${var.environment}"

  # A certificate is the single switch for TLS: supplying one adds the 443
  # listener, turns port 80 into a redirect, and opens 443 on the ALB security
  # group. Leaving it empty keeps the stack HTTP-only.
  enable_https = var.acm_certificate_arn != ""

  # Supplying an image is what turns the frontend on, the same way supplying a
  # certificate is what turns HTTPS on. With it empty the ALB keeps forwarding
  # everything to the backend and no frontend resources are created.
  enable_frontend = var.frontend_container_image != ""

  # Falls back to the backend's architecture unless the frontend declares its
  # own — the two images are built independently and can differ.
  frontend_cpu_architecture = var.frontend_cpu_architecture != "" ? var.frontend_cpu_architecture : var.container_cpu_architecture

  # Redirecting port 80 needs somewhere to redirect TO, so it requires the
  # certificate as well as the switch. With the switch off, 80 keeps serving
  # the app directly and 443 runs alongside it.
  redirect_http_to_https = local.enable_https && var.alb_http_redirect_to_https

  # IAM roles and policies are GLOBAL, not regional — a role named
  # "alphapro-dev-ecs-task" in us-east-1 blocks that same name in
  # ap-southeast-1. Region-qualifying IAM names lets the same stack exist in
  # more than one region without sharing or colliding. Every other resource
  # in this module is regional and needs no such qualification.
  iam_prefix = "${var.project}-${var.environment}-${var.aws_region}"

  # Major engine version drives both the parameter group family and its name
  # (the live stack names it "<project>-<env>-pg17").
  db_engine_major = split(".", var.db_engine_version)[0]

  # When db_host is empty, Terraform creates and manages the RDS instance and
  # its secret. When set, it reuses an existing database and existing secret.
  create_database = var.db_host == ""

  default_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )

  # Queue types and how they map to Shopify webhook topics. inventory & orders
  # are FIFO (ordered), products is a standard queue.
  queue_config = {
    inventory = { fifo = true, topic_prefix = "inventory_levels/" }
    orders    = { fifo = true, topic_prefix = "orders/" }
    products  = { fifo = false, topic_prefix = "products/" }
  }

  # Cartesian product of stores x queue types, keyed "ksa-inventory", etc.
  # This single map drives SQS queues, DLQs, queue policies, EventBridge rules
  # and targets, consumer task definitions/services, autoscaling, and alarms.
  # Cartesian product of stores x their enabled workers, keyed
  # "uae-orders", "uae-products", ... — the same shape as store_queues, so
  # enabling one worker is additive and never reshuffles the others.
  store_workers = merge([
    for sid, s in var.stores : {
      for name, sy in try(s.workers, {}) :
      "${sid}-${name}" => {
        store_id    = sid
        store_name  = s.store_name
        worker_name = name
        args        = sy.args
      }
      if sy.enabled
    }
  ]...)

  store_queues = merge([
    for sid, s in var.stores : {
      for qt, qc in local.queue_config :
      "${sid}-${qt}" => {
        store_id   = sid
        store_name = s.store_name
        # Shared across every store — see var.app_url's description.
        app_url = var.app_url
        # This store's own bus. All 3 of its rules attach here and separate
        # from each other by X-Shopify-Topic prefix.
        event_bus    = s.event_bus
        queue_type   = qt
        fifo         = qc.fifo
        topic_prefix = qc.topic_prefix
        # FIFO queue/DLQ names carry the .fifo suffix.
        queue_name = qc.fifo ? "${var.project}-${var.environment}-${sid}-${qt}.fifo" : "${var.project}-${var.environment}-${sid}-${qt}"
        dlq_name   = qc.fifo ? "${var.project}-${var.environment}-${sid}-${qt}-dlq.fifo" : "${var.project}-${var.environment}-${sid}-${qt}-dlq"
      }
    }
  ]...)

  # Which (store, queue type) pairs actually get a consumer service.
  #
  # Deliberately NOT applied to store_queues itself: the SQS queues, DLQs and
  # EventBridge rules stay in place for every type regardless, so a paused type
  # keeps accumulating webhooks instead of dropping them on the floor. Only the
  # compute that drains them is switched off.
  active_consumers = var.enable_consumers ? {
    for k, v in local.store_queues : k => v
    if contains(var.consumer_queue_types, v.queue_type)
  } : {}
}
