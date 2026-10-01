###############################################################################
# Core / identity
###############################################################################

variable "project" {
  description = "Project name, used as a prefix for all resource names (e.g. alphapro)."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "tags" {
  description = "Extra tags merged into the default tag set."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ)."
  type        = list(string)
}

variable "allowed_db_cidrs" {
  description = "List of CIDR blocks allowed to reach the database directly (office / VPN IPs)."
  type        = list(string)
  default     = []
}

variable "enable_quicksight_access" {
  description = "Create a QuickSight security group and allow it to reach the database on 5432."
  type        = bool
  default     = true
}

variable "nat_gateway_multi_az" {
  description = <<-EOT
    One NAT Gateway + Elastic IP per AZ (AZ-redundant, N static egress IPs)
    instead of a single shared one (1 static IP, no AZ redundancy). More IPs
    means more addresses to hand third parties for outbound IP whitelisting.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Compute (ECS Fargate)
###############################################################################

variable "container_image" {
  description = "Full container image URI (including tag) used by all tasks."
  type        = string
}

variable "infra_release_version" {
  description = "Release version stamp passed to containers as INFRA_RELEASE_VERSION."
  type        = string
  default     = ""
}

variable "container_cpu_architecture" {
  description = <<-EOT
    CPU architecture of the container image in var.container_image. This MUST
    match how the image was actually built, or every task dies at startup with
    "exec format error" — and it fails silently: plan and apply both succeed.

    It depends entirely on the build environment, so it lives here rather than
    hardcoded in the module:
      - docker build on an Apple Silicon Mac  -> ARM64 (the default)
      - docker build on an Intel Mac          -> X86_64
      - GitHub Actions ubuntu-latest runner   -> X86_64
      - buildx --platform linux/arm64         -> ARM64 regardless of host

    ARM64 is ~20% cheaper per vCPU-hour on Fargate. The old deployed stack ran
    ARM64 on FARGATE_SPOT across all 7 services, so that combination is known
    to work in this account.
  EOT
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.container_cpu_architecture)
    error_message = "container_cpu_architecture must be ARM64 or X86_64."
  }
}

###############################################################################
# Frontend (SPA served by nginx, behind the SAME ALB)
###############################################################################

variable "frontend_container_image" {
  description = <<-EOT
    Full image URI for the frontend container, e.g.
    <acct>.dkr.ecr.<region>.amazonaws.com/squatwolf/dev/alfapro-frontend:latest

    Empty (the default) disables the frontend entirely: no target group, no
    listener rules, no service, and the ALB keeps forwarding everything to the
    backend exactly as it does today. Setting it adds a host-based listener
    rule alongside the backend's untouched default action — see var.frontend_host_header.
  EOT
  type        = string
  default     = ""
}

variable "frontend_host_header" {
  description = <<-EOT
    Hostname that routes to the FRONTEND, e.g. dev.alfapro.ai.

    The frontend is added purely as a listener rule: this Host header forwards
    to the frontend target group, and the listener's default action is left
    alone, so the backend keeps serving every other host exactly as it does
    today. Adding or removing the frontend cannot change backend routing.

    Must resolve to this ALB in DNS and be covered by var.acm_certificate_arn,
    or HTTPS clients get a certificate name mismatch.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.frontend_container_image == "" || var.frontend_host_header != ""
    error_message = "frontend_host_header is required when frontend_container_image is set — without it the frontend has no route."
  }
}

variable "frontend_cpu_architecture" {
  description = <<-EOT
    CPU architecture of the frontend image. Empty (the default) inherits
    var.container_cpu_architecture, which is usually right when both images
    come off the same machine.

    Set it when they don't. The backend and frontend live in separate repos
    and are often built by different pipelines, so their architectures drift
    apart independently — a mismatch surfaces at task start as
    "image Manifest does not contain descriptor matching platform".
  EOT
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "ARM64", "X86_64"], var.frontend_cpu_architecture)
    error_message = "frontend_cpu_architecture must be ARM64, X86_64, or empty to inherit container_cpu_architecture."
  }
}

variable "frontend_port" {
  description = "Container/target-group port for the frontend. 80 when nginx serves the built assets."
  type        = number
  default     = 80
}

variable "frontend_health_check_path" {
  description = "ALB health check path for the frontend. A SPA usually answers 200 at /, since nginx serves index.html for any unmatched route."
  type        = string
  default     = "/"
}

variable "frontend_desired_count" {
  description = "Desired number of frontend tasks."
  type        = number
  default     = 1
}

variable "frontend_min_capacity" {
  description = "Minimum frontend tasks for autoscaling."
  type        = number
  default     = 1
}

variable "frontend_max_capacity" {
  description = "Maximum frontend tasks for autoscaling."
  type        = number
  default     = 4
}

variable "frontend_env" {
  description = <<-EOT
    Extra environment variables for the frontend container, as a plain map.

    IMPORTANT: Vite inlines VITE_* values at BUILD time — `vite build` replaces
    them literally in the bundle. If the image serves a pre-built SPA through
    nginx, setting them here changes nothing at runtime; they must be passed as
    --build-arg when the image is built. They are still injected because some
    nginx SPA images template a runtime config file from the environment on
    container start.
  EOT
  type        = map(string)
  default     = {}
}

variable "web_env" {
  description = <<-EOT
    Extra environment variables for the web container, as a plain map. Merged
    on top of the ones the module derives itself (endpoints, ports, bucket
    names), so this is the place for application-level settings Terraform has
    no opinion about — APP_NAME, APP_VERSION, DEBUG and similar.

    Keys are sorted before injection so the task definition diff stays stable;
    an unsorted map reorders between plans and shows phantom changes.
  EOT
  type        = map(string)
  default     = {}
}

variable "capacity_provider_strategy" {
  description = <<-EOT
    Capacity provider strategy applied to every ECS service. Defaults to 100%
    Fargate Spot (base 1, weight 1), which is what the live dev stack runs.
    Set to [{capacity_provider = "FARGATE", base = 1, weight = 1}] for
    on-demand, or to [] to inherit the cluster's default strategy. This is
    mutually exclusive with launch_type, which the module no longer sets.
  EOT
  type = list(object({
    capacity_provider = string
    base              = optional(number, 0)
    weight            = optional(number, 1)
  }))
  default = [{ capacity_provider = "FARGATE_SPOT", base = 1, weight = 1 }]

  validation {
    condition = alltrue([
      for s in var.capacity_provider_strategy :
      contains(["FARGATE", "FARGATE_SPOT"], s.capacity_provider)
    ])
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "deployment_maximum_percent" {
  description = "Upper bound on running tasks during a deployment, as a percent of desired count."
  type        = number
  default     = 200
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower bound on healthy tasks during a deployment, as a percent of desired count."
  type        = number
  default     = 100
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "web_port" {
  description = "Container/listener port for the web service."
  type        = number
  default     = 8000
}

variable "web_desired_count" {
  description = "Desired number of web tasks."
  type        = number
  default     = 1
}

variable "web_min_capacity" {
  description = "Minimum web tasks for autoscaling."
  type        = number
  default     = 1
}

variable "web_max_capacity" {
  description = "Maximum web tasks for autoscaling."
  type        = number
  default     = 10
}

variable "enable_consumers" {
  description = <<-EOT
    Create the per-store consumer ECS services (and their task definitions,
    autoscaling, and no-running-tasks alarms). Set false to stand the stack up
    without running consumers — e.g. while the database is unreachable, so
    nothing crashloops.

    Deliberately does NOT gate the SQS queues, EventBridge rules, or targets:
    those keep running, so Shopify webhooks continue landing in SQS and
    accumulate (4-day retention). Turning consumers back on drains the backlog.
    Disabling the STORE instead would delete the rules and silently drop every
    webhook for as long as it stayed off.

    The no-running-tasks alarms are gated too — with no service to watch they
    use treat_missing_data = "breaching" and would sit in permanent ALARM.
  EOT
  type        = bool
  default     = true
}

variable "consumer_queue_types" {
  description = <<-EOT
    Which queue types get a consumer service, out of inventory, orders and
    products. Applies to every store — there is no per-store override, because
    a store processing a different set of webhooks than its siblings is far more
    often a mistake than an intention.

    Dropping a type here removes its 4 services (one per store) and their
    no-running-tasks alarms. It does NOT touch that type's SQS queues, DLQs or
    EventBridge rules, so webhooks keep arriving and queue up for whenever the
    consumers come back. Watch the queue retention window if a type stays off
    for long — messages past it are gone.

    Has no effect at all while enable_consumers is false.
  EOT
  type        = list(string)
  default     = ["inventory", "orders", "products"]

  validation {
    condition     = length(setsubtract(var.consumer_queue_types, ["inventory", "orders", "products"])) == 0
    error_message = "consumer_queue_types may only contain: inventory, orders, products."
  }
}

variable "worker_desired_count" {
  description = <<-EOT
    Tasks per enabled sync service. 1 is almost always right — a worker is
    rate-limited by Shopify's API, so a second task duplicates work instead of
    halving the time. Set 0 to pause every worker without removing the services.
  EOT
  type        = number
  default     = 1
}

variable "consumer_desired_count" {
  description = "Desired number of tasks per consumer service."
  type        = number
  default     = 1
}

variable "consumer_min_capacity" {
  description = "Minimum tasks per consumer service for autoscaling."
  type        = number
  default     = 1
}

variable "consumer_max_capacity" {
  description = "Maximum tasks per consumer service for autoscaling."
  type        = number
  default     = 5
}

variable "autoscaling_cpu_target" {
  description = "Target average CPU utilization (%) for target-tracking autoscaling."
  type        = number
  default     = 70
}

variable "scale_out_cooldown" {
  description = "Scale-out cooldown in seconds."
  type        = number
  default     = 60
}

variable "scale_in_cooldown" {
  description = "Scale-in cooldown in seconds."
  type        = number
  default     = 300
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an ACM certificate for the ALB's HTTPS listener.

    The certificate MUST live in var.aws_region. An ALB can only use a cert
    from its own region — the us-east-1-only rule applies to CloudFront, not
    ALBs, and is a common source of "certificate not found" on apply.

    Empty (the default) keeps the stack HTTP-only: port 80 forwards to the
    target group and no 443 listener exists. Supplying an ARN adds the 443
    listener, turns port 80 into a 301 redirect to it, and opens 443 on the
    ALB security group.

    Terraform does not request the certificate — issue and validate it in ACM
    first, then paste the ARN here.
  EOT
  type        = string
  default     = ""
}

variable "alb_http_redirect_to_https" {
  description = <<-EOT
    Redirect port 80 to 443 with a 301 instead of serving the app over plain
    HTTP. Only has an effect when var.acm_certificate_arn is set, since a
    redirect needs a 443 listener to land on.

    Turning this off leaves port 80 serving the application unencrypted
    alongside HTTPS. That is sometimes wanted — internal HTTP clients, probes,
    or debugging — but it does mean traffic on 80 is never upgraded.
  EOT
  type        = bool
  default     = true
}

variable "alb_ssl_policy" {
  description = <<-EOT
    TLS security policy for the HTTPS listener. The default negotiates TLS 1.3
    and 1.2 only, dropping TLS 1.0/1.1 — safe for browsers and for Shopify's
    webhook delivery. Override only if a client genuinely needs older TLS.
  EOT
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "health_check_path" {
  description = "ALB target group health check path."
  type        = string
  default     = "/health"
}

variable "health_check_timeout" {
  description = "ALB target group health check timeout in seconds. Must be less than the interval."
  type        = number
  default     = 10

  # The interval is hardcoded to 30 in alb.tf, not a variable — if that ever
  # changes, update the bound below to match. Without this, AWS's own
  # InvalidParameterValue rejection only ever surfaces at apply time, not
  # plan time.
  validation {
    condition     = var.health_check_timeout < 30
    error_message = "health_check_timeout must be less than the health check interval (30s, alb.tf)."
  }
}

variable "web_health_check_grace_period" {
  description = "Seconds the web service ignores ALB health checks after a task starts (covers Alembic migrations on boot)."
  type        = number
  default     = 60
}

variable "container_insights" {
  description = "Enable ECS Container Insights on the cluster."
  type        = bool
  default     = true
}

variable "enable_deployment_circuit_breaker" {
  description = <<-EOT
    Let ECS abandon a rolling deployment whose tasks keep failing to start,
    and roll the service back to the last revision that reached a steady state.

    Off by default, which is also the AWS default: a deployment then retries
    forever, so a task definition that can never start (a missing secret key, a
    container exiting non-zero) leaves the service IN_PROGRESS indefinitely
    rather than reporting failure.

    Rollback needs a previous successful revision to return to, so on a service's
    very first deployment it can only fail fast, not recover. It pairs with
    skip_destroy on the task definitions, which keeps every earlier revision
    registered and therefore available as a rollback target.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Stores (Shopify integration)
###############################################################################

variable "stores" {
  description = <<-EOT
    Map of stores keyed by store id (e.g. ksa, uae). Each value supplies the
    human store name and that store's OWN Shopify partner EventBridge bus,
    e.g. aws.partner/shopify.com/<partner-account-id>/<source-name>.

    One bus per store, not one shared bus and not one per queue type. That
    isolation is what keeps each store's webhooks in its own queues: the 3
    rules for a store (inventory/orders/products) all attach to that store's
    bus and separate from each other by X-Shopify-Topic prefix.

    Terraform does NOT create these buses. Shopify's EventBridge app creates
    a partner event source per store, which you then associate with a bus in
    the AWS console. Each bus is region-scoped and must exist in
    var.aws_region, or that store's rules fail with no bus to attach to.

    This map drives the whole per-store fan-out: SQS queues, DLQs, EventBridge
    rules, consumer ECS services, and alarms.
  EOT
  type = map(object({
    store_name = string
    event_bus  = string

    # Optional workers for this store, keyed by a name of your choosing
    # (orders, products, inventory, ...). Each becomes its own ECS service, so
    # they scale, fail and are paused independently. Omit the map entirely and
    # the store gets none — the default, so existing stores are unaffected.
    #
    # args is the full argument list passed after `python -m app.cli.main`, so
    # the command shape stays the store's choice rather than something this
    # module hardcodes.
    workers = optional(map(object({
      enabled = optional(bool, true)
      args    = list(string)
    })), {})
  }))

  validation {
    condition = alltrue(flatten([
      for sid, s in var.stores : [
        for name, sy in try(s.workers, {}) :
        !sy.enabled || length(sy.args) > 0
      ]
    ]))
    error_message = "An enabled sync must supply a non-empty args list — otherwise the CLI starts with no subcommand."
  }
}

variable "app_url" {
  description = <<-EOT
    URL of the shared web app that consumer tasks call back into. One value
    per environment, not per store — every consumer, regardless of which
    store it's processing, calls the same running web service.
  EOT
  type        = string
}

variable "sqs_receive_wait_time_seconds" {
  description = "Long-poll wait on the main SQS queues (0-20). 0 means short polling and far more empty receives."
  type        = number
  default     = 20

  validation {
    condition     = var.sqs_receive_wait_time_seconds >= 0 && var.sqs_receive_wait_time_seconds <= 20
    error_message = "sqs_receive_wait_time_seconds must be between 0 and 20."
  }
}

variable "shopify_sqs_strict_hmac" {
  description = "Value for the SHOPIFY_SQS_STRICT_HMAC consumer env var."
  type        = string
  default     = "false"
}

###############################################################################
# Database (RDS PostgreSQL)
###############################################################################

variable "db_host" {
  description = <<-EOT
    Endpoint host of an EXISTING database to reuse. When set, Terraform does not
    create the RDS instance / parameter group / subnet group / database secret;
    it points the app at this host and reads the existing secret for credentials.
    Leave empty to have Terraform create and manage a new RDS instance.
  EOT
  type        = string
  default     = ""
}

variable "db_engine_version" {
  description = <<-EOT
    PostgreSQL engine version. A major-version-only string (e.g. "18") lets
    RDS pick its current latest minor at creation time; the provider doesn't
    re-diff on later minor auto-upgrades when specified this way. A full
    "major.minor" string pins exactly.
  EOT
  type        = string
  default     = "18"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage (GB)."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Max storage for storage autoscaling (GB)."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "alphapro"
}

variable "db_username" {
  description = "Master DB username."
  type        = string
  default     = "alphapro_admin"
}

variable "db_port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "db_backup_retention_period" {
  description = "Backup retention period in days."
  type        = number
  default     = 1
}

variable "db_deletion_protection" {
  description = "Enable deletion protection on the DB instance."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy."
  type        = bool
  default     = true
}

variable "db_publicly_accessible" {
  description = "Whether the DB instance is publicly accessible."
  type        = bool
  default     = true
}

###############################################################################
# Cache (ElastiCache Valkey)
###############################################################################

variable "valkey_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "valkey_engine_version" {
  description = "Valkey engine version."
  type        = string
  default     = "8.0"
}

variable "valkey_num_cache_clusters" {
  description = "Number of nodes per replication group."
  type        = number
  default     = 1
}

variable "valkey_automatic_failover" {
  description = "Enable automatic failover (requires >=2 nodes)."
  type        = bool
  default     = false
}

variable "broker_port" {
  description = "Port for the Celery broker Valkey replication group."
  type        = number
  default     = 6379
}

variable "cache_port" {
  description = "Port for the application cache Valkey replication group."
  type        = number
  default     = 6380
}

###############################################################################
# Storage (S3 assets)
###############################################################################

variable "s3_bucket_name" {
  description = <<-EOT
    Globally-unique S3 bucket name for application assets, read/written/deleted
    directly by ECS tasks. No default — S3 bucket names are unique across all
    of AWS, not just this account, so this must be chosen explicitly per
    environment.
  EOT
  type        = string
}

###############################################################################
# Secrets
###############################################################################

variable "docs_enabled" {
  description = <<-EOT
    Expose the API documentation endpoint. Plain config, not a credential, so
    it travels as an ordinary container environment variable. The username and
    password that guard it live in Secrets Manager instead — see
    var.app_secret_value.
  EOT
  type        = bool
  default     = false
}

variable "app_secret_value" {
  description = <<-EOT
    Initial JSON for the application secret (<project>/<env>/app). Seed it as
    {} and set the real credentials in the Secrets Manager console — the secret
    version carries ignore_changes, so applies never overwrite them.

    Holds every credential this application owns itself: Shopify integration
    keys, and the API docs basic-auth pair. Two keys are read by name from the
    web task definition:

      docs_username, docs_password

    Shopify keys are read by the application, not injected by Terraform, so
    their naming is the app's choice.

    The database secret is deliberately NOT here — its owner is the database.
  EOT
  type        = string
  default     = "{}"
  sensitive   = true
}

###############################################################################
# Observability
###############################################################################

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "Email address subscribed to the alarms SNS topic."
  type        = string
}

variable "alarm_queue_depth_threshold" {
  description = "Queue depth (visible messages) that triggers the queue-depth alarm."
  type        = number
  default     = 1000
}
