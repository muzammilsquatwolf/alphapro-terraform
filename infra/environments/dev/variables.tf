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
    CPU architecture of the container image in var.container_image. MUST match
    how the image was actually built, or every task dies at startup with
    "exec format error" (silently — plan and apply both succeed).
    Apple Silicon Mac build -> ARM64. Intel Mac or GitHub Actions
    ubuntu-latest -> X86_64. buildx --platform wins over the host either way.
  EOT
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.container_cpu_architecture)
    error_message = "container_cpu_architecture must be ARM64 or X86_64."
  }
}

###############################################################################
# Frontend (SPA behind the same ALB)
###############################################################################

variable "frontend_container_image" {
  description = "Full image URI for the frontend container. Empty disables the frontend entirely."
  type        = string
  default     = ""
}

variable "frontend_host_header" {
  description = "Hostname routed to the FRONTEND (e.g. dev.alfapro.ai). Added as a listener rule; the backend keeps the default action and is untouched."
  type        = string
  default     = ""

  validation {
    condition     = var.frontend_container_image == "" || var.frontend_host_header != ""
    error_message = "frontend_host_header is required when frontend_container_image is set."
  }
}

variable "frontend_cpu_architecture" {
  description = "CPU architecture of the frontend image. Empty inherits container_cpu_architecture; set it when the two images are built differently."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "ARM64", "X86_64"], var.frontend_cpu_architecture)
    error_message = "frontend_cpu_architecture must be ARM64, X86_64, or empty."
  }
}

variable "frontend_port" {
  description = "Container/target-group port for the frontend (80 when nginx serves the build)."
  type        = number
  default     = 80
}

variable "frontend_health_check_path" {
  description = "ALB health check path for the frontend."
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
  description = "Extra environment variables for the frontend container. NOTE: VITE_* are inlined at build time, so these only take effect if the image templates a runtime config."
  type        = map(string)
  default     = {}
}

variable "web_env" {
  description = "Extra environment variables for the web container (APP_NAME, APP_VERSION, DEBUG, ...). Merged on top of the module-derived ones."
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
    Create the per-store consumer ECS services (plus task definitions,
    autoscaling, and no-running-tasks alarms). False stands the stack up
    without consumers running. SQS queues and EventBridge rules are NOT gated,
    so webhooks keep landing in SQS and accumulate for later processing.
  EOT
  type        = bool
  default     = true
}

variable "consumer_module" {
  description = "Python module each consumer runs, as `python -m <module>`. With one queue per store it must dispatch on X-Shopify-Topic itself."
  type        = string
  default     = "app.workers.sqs_consumer"
}

variable "worker_desired_count" {
  description = "Tasks per enabled sync service. 1 is normal; 0 pauses all workers without removing them."
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
    ARN of an ACM certificate for the ALB's HTTPS listener. Must be issued in
    var.aws_region — an ALB cannot use a certificate from another region.
    Empty = HTTP only. Setting it adds a 443 listener and redirects 80 to it.
  EOT
  type        = string
  default     = ""
}

variable "alb_http_redirect_to_https" {
  description = "Redirect port 80 to 443 (301) instead of serving the app over plain HTTP. Requires a certificate."
  type        = bool
  default     = true
}

variable "alb_ssl_policy" {
  description = "TLS security policy for the HTTPS listener (TLS 1.3 + 1.2 by default)."
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
    human store name and that store's OWN Shopify partner EventBridge bus.
    One bus per store — that isolation is what keeps each store's webhooks in
    its own queues. Terraform does not create the buses; associate each
    store's partner event source in the console first, in var.aws_region.
  EOT
  type = map(object({
    store_name = string
    event_bus  = string


    consumer_enabled = optional(bool)

    # Optional workers, keyed by name (orders, products, inventory, ...).
    # Each becomes its own ECS service. args is the full argument list after
    # `python -m app.cli.main`.
    workers = optional(map(object({
      enabled = optional(bool, true)
      args    = list(string)
    })), {})
  }))

  validation {
    condition = alltrue(flatten([
      for sid, s in var.stores : [
        for name, sy in try(s.workers, {}) : !sy.enabled || length(sy.args) > 0
      ]
    ]))
    error_message = "An enabled sync must supply a non-empty args list."
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

variable "enable_celery_queue" {
  description = <<-EOT
    Create an SQS queue for Celery and inject its URL into the web, consumer
    and worker tasks as CELERY_SQS_QUEUE_URLS.

    Separate from the per-store webhook queues, which EventBridge fills and the
    consumers drain — this one carries the application's own background tasks.
    Off leaves the variable absent rather than empty, so the application can
    tell "no SQS broker configured" from "configured and broken".
  EOT
  type        = bool
  default     = false
}

variable "celery_worker_desired_count" {
  description = "Number of Celery worker tasks. 0 pauses the worker while keeping the service and its task definition in place. Only has an effect when enable_celery_queue is true."
  type        = number
  default     = 1
}

variable "celery_beat_desired_count" {
  description = "Celery beat tasks. 1 or 0 — beat is a singleton, and two instances would double-fire every scheduled job. 0 pauses the scheduler while keeping the service in place. Only applies when enable_celery_queue is true."
  type        = number
  default     = 1

  validation {
    condition     = var.celery_beat_desired_count <= 1
    error_message = "celery_beat_desired_count must be 0 or 1 — beat is a singleton."
  }
}

variable "sitemap_desired_count" {
  description = "Tasks for the sitemap service. The job exits when it finishes, so a count of 1 means it regenerates continuously; 0 stops it and leaves the task definition registered for manual runs."
  type        = number
  default     = 0
}

variable "enable_mongodb" {
  description = "Inject MONGODB_URL into the web, consumer and worker tasks, read from the MONGODB_URL key of this environment's database secret. Off where that key does not exist — a task cannot start without a key it references."
  type        = bool
  default     = false
}

variable "documentdb_port" {
  description = "Port the DocumentDB cluster listens on. 27017 is the default; it is fixed when the cluster is created, so check the cluster rather than assuming."
  type        = number
  default     = 27017
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
  description = "PostgreSQL engine version."
  type        = string
  default     = "17.6"
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
  default     = false
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

variable "enable_public_assets" {
  description = "Serve the public_assets_prefix of the assets bucket through CloudFront. The bucket itself stays private."
  type        = bool
  default     = false
}

variable "public_assets_prefix" {
  description = "Key prefix within the assets bucket that CloudFront serves. No leading or trailing slash."
  type        = string
  default     = "public"
}


variable "public_assets_host" {
  description = "Hostname serving the public assets, e.g. asset.squatwolf.com. Each store writes under its own prefix, so URLs read <host>/<store>/sitemap.xml. Requires public_assets_certificate_arn; without both, CloudFront serves on its own *.cloudfront.net domain."
  type        = string
  default     = ""
}


variable "public_assets_certificate_arn" {
  description = "ACM certificate for public_assets_host. MUST be in us-east-1 — CloudFront reads certificates from no other region."
  type        = string
  default     = ""
}

###############################################################################
# Secrets
###############################################################################

variable "docs_enabled" {
  description = "Expose the API documentation endpoint. Plain config; the credentials guarding it live in Secrets Manager."
  type        = bool
  default     = false
}

variable "app_secret_value" {
  description = "Initial JSON for the application secret (Shopify + API docs credentials). Seed {} and set real values in the console."
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
