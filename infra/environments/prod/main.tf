module "alphapro" {
  source = "../../modules/alphapro"

  # Identity
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  tags        = var.tags

  # Networking
  vpc_cidr                 = var.vpc_cidr
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_subnet_cidrs     = var.private_subnet_cidrs
  allowed_db_cidrs         = var.allowed_db_cidrs
  enable_quicksight_access = var.enable_quicksight_access
  nat_gateway_multi_az     = var.nat_gateway_multi_az

  # Compute
  container_image                    = var.container_image
  web_env                            = var.web_env
  frontend_container_image           = var.frontend_container_image
  frontend_host_header               = var.frontend_host_header
  frontend_cpu_architecture          = var.frontend_cpu_architecture
  frontend_port                      = var.frontend_port
  frontend_health_check_path         = var.frontend_health_check_path
  frontend_desired_count             = var.frontend_desired_count
  frontend_min_capacity              = var.frontend_min_capacity
  frontend_max_capacity              = var.frontend_max_capacity
  frontend_env                       = var.frontend_env
  infra_release_version              = var.infra_release_version
  container_cpu_architecture         = var.container_cpu_architecture
  capacity_provider_strategy         = var.capacity_provider_strategy
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  task_cpu                           = var.task_cpu
  task_memory                        = var.task_memory
  web_port                           = var.web_port
  web_desired_count                  = var.web_desired_count
  web_min_capacity                   = var.web_min_capacity
  web_max_capacity                   = var.web_max_capacity
  enable_consumers                   = var.enable_consumers
  consumer_module                    = var.consumer_module
  worker_desired_count               = var.worker_desired_count
  consumer_desired_count             = var.consumer_desired_count
  consumer_min_capacity              = var.consumer_min_capacity
  consumer_max_capacity              = var.consumer_max_capacity
  autoscaling_cpu_target             = var.autoscaling_cpu_target
  scale_out_cooldown                 = var.scale_out_cooldown
  scale_in_cooldown                  = var.scale_in_cooldown
  acm_certificate_arn                = var.acm_certificate_arn
  alb_http_redirect_to_https         = var.alb_http_redirect_to_https
  alb_ssl_policy                     = var.alb_ssl_policy
  health_check_path                  = var.health_check_path
  health_check_timeout               = var.health_check_timeout
  web_health_check_grace_period      = var.web_health_check_grace_period
  container_insights                 = var.container_insights
  enable_deployment_circuit_breaker  = var.enable_deployment_circuit_breaker

  # Stores
  stores                        = var.stores
  app_url                       = var.app_url
  shopify_sqs_strict_hmac       = var.shopify_sqs_strict_hmac
  sqs_receive_wait_time_seconds = var.sqs_receive_wait_time_seconds
  enable_celery_queue           = var.enable_celery_queue
  celery_worker_desired_count   = var.celery_worker_desired_count
  enable_mongodb                = var.enable_mongodb
  documentdb_port               = var.documentdb_port

  # Database
  db_host                    = var.db_host
  db_engine_version          = var.db_engine_version
  db_instance_class          = var.db_instance_class
  db_allocated_storage       = var.db_allocated_storage
  db_max_allocated_storage   = var.db_max_allocated_storage
  db_name                    = var.db_name
  db_username                = var.db_username
  db_port                    = var.db_port
  db_multi_az                = var.db_multi_az
  db_backup_retention_period = var.db_backup_retention_period
  db_deletion_protection     = var.db_deletion_protection
  db_skip_final_snapshot     = var.db_skip_final_snapshot
  db_publicly_accessible     = var.db_publicly_accessible

  # Cache
  valkey_node_type          = var.valkey_node_type
  valkey_engine_version     = var.valkey_engine_version
  valkey_num_cache_clusters = var.valkey_num_cache_clusters
  valkey_automatic_failover = var.valkey_automatic_failover
  broker_port               = var.broker_port
  cache_port                = var.cache_port

  # Storage
  s3_bucket_name = var.s3_bucket_name

  # Secrets
  docs_enabled     = var.docs_enabled
  app_secret_value = var.app_secret_value

  # Observability
  log_retention_days          = var.log_retention_days
  alarm_email                 = var.alarm_email
  alarm_queue_depth_threshold = var.alarm_queue_depth_threshold
}
