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

  # Shopify webhook topics routed into each store's queue. fifo is gone from
  # here: the store queue is FIFO for everything now, and the three types stay
  # separated by message group rather than by queue.
  queue_config = {
    inventory = { topic_prefix = "inventory_levels/" }
    orders    = { topic_prefix = "orders/" }
    products  = { topic_prefix = "products/" }
  }

  # Cartesian product of stores x their enabled workers, keyed
  # "uae-orders", "uae-products", ... — enabling one worker is additive and
  # never reshuffles the others.
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

  # ONE queue per store, not one per store x type.
  #
  # The three types share it and stay apart by SQS message group — see
  # local.store_rules. FIFO delivers different groups in parallel, so orders,
  # products and inventory still process concurrently and still keep order
  # within themselves; what changes is that a single consumer drains all three
  # instead of three consumers draining one each.
  #
  # Always created, for every store, regardless of whether a consumer runs.
  # A store with its consumer off keeps accumulating webhooks rather than
  # dropping them.
  store_queues = {
    for sid, s in var.stores : sid => {
      store_id   = sid
      store_name = s.store_name
      app_url    = var.app_url
      event_bus  = s.event_bus
      queue_name = "${var.project}-${var.environment}-${sid}.fifo"
      dlq_name   = "${var.project}-${var.environment}-${sid}-dlq.fifo"
    }
  }

  # EventBridge still needs one rule per (store, type): a rule lives on exactly
  # one bus and matches exactly one topic prefix, and each store has its own
  # bus. All three of a store's rules now target that store's single queue.
  #
  # message_group_id is the queue type. That is what preserves per-type
  # ordering inside a shared queue, and what keeps a stuck message in one type
  # from blocking the other two.
  store_rules = merge([
    for sid, s in var.stores : {
      for qt, qc in local.queue_config :
      "${sid}-${qt}" => {
        store_id         = sid
        queue_type       = qt
        event_bus        = s.event_bus
        topic_prefix     = qc.topic_prefix
        message_group_id = qt
      }
    }
  ]...)

  # Rule ARNs grouped by store, so each queue policy can admit exactly the
  # three rules that feed it and nothing else.
  store_rule_arns = {
    for sid in keys(var.stores) : sid => [
      for k, r in local.store_rules : aws_cloudwatch_event_rule.this[k].arn if r.store_id == sid
    ]
  }

  # One consumer per store. Per-store flag first, then the environment-wide
  # default, then true — written as explicit null checks because coalesce()
  # skips false as well as null, which would make "consumer_enabled = false"
  # silently inherit the default instead.
  active_consumers = var.enable_consumers ? {
    for sid, q in local.store_queues : sid => q
    if try(var.stores[sid].consumer_enabled, null) != null ? var.stores[sid].consumer_enabled : true
  } : {}

  # Appended to the web, consumer and worker environments. An empty list when
  # the queue is off, so the variable is absent rather than set to "" — the
  # application can then tell "no SQS broker" from "broker configured but
  # broken", which an empty string would hide.
  celery_queue_env = var.enable_celery_queue ? [
    # JSON-encoded, not the bare URL. The field is plural and typed as a
    # collection in the application's pydantic Settings, so pydantic-settings
    # treats it as a complex value and json.loads() it — a plain URL fails at
    # "Expecting value: line 1 column 1" before anything else runs.
    { name = "CELERY_SQS_QUEUE_URLS", value = jsonencode([one(aws_sqs_queue.celery[*].url)]) },
    # Read off the queue rather than written out by hand. The literal
    # "alphapro-production-celery.fifo" would silently stop matching the moment
    # project or environment changes — and a Celery default queue that names a
    # queue which does not exist fails at publish time, not at boot.
    { name = "CELERY_DEFAULT_QUEUE", value = one(aws_sqs_queue.celery[*].name) },
  ] : []

  # Gated because the key is per environment: alphapro/dev/database has no
  # MONGODB_URL, and a task asking for a key its secret lacks dies at container
  # start with "did not contain json key" — before the application runs.
  mongodb_secret = var.enable_mongodb ? [
    { name = "MONGODB_URL", valueFrom = "${local.database_secret_arn}:MONGODB_URL::" }
  ] : []
}
