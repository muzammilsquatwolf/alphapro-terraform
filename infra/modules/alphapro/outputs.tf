output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "nat_gateway_public_ips" {
  description = "Static outbound (egress) IP address(es) every ECS service shares — hand these to third parties for IP whitelisting."
  value       = { for k, eip in aws_eip.nat : k => eip.public_ip }
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "web_service" {
  description = "Web ECS service name."
  value       = aws_ecs_service.web.name
}

output "db_endpoint" {
  description = "Writable database endpoint (host:port) — the created Aurora cluster's writer, or the reused existing host."
  value       = "${local.db_host}:${var.db_port}"
  sensitive   = true
}

output "db_reader_endpoint" {
  description = "Aurora reader endpoint (host:port), load-balanced across the replicas. Null when reusing an existing database or running a single instance."
  value       = local.create_database ? "${one(aws_rds_cluster.this[*].reader_endpoint)}:${var.db_port}" : null
  sensitive   = true
}

output "valkey_endpoint" {
  description = "Valkey broker primary endpoint."
  value       = aws_elasticache_replication_group.broker.primary_endpoint_address
  sensitive   = true
}

output "valkey_cache_endpoint" {
  description = "Valkey cache primary endpoint."
  value       = aws_elasticache_replication_group.cache.primary_endpoint_address
  sensitive   = true
}

output "assets_bucket_name" {
  description = "S3 bucket name for application assets."
  value       = aws_s3_bucket.assets.id
}

output "assets_bucket_arn" {
  description = "S3 bucket ARN for application assets."
  value       = aws_s3_bucket.assets.arn
}

output "alarm_sns_topic_arn" {
  description = "ARN of the alarms SNS topic."
  value       = aws_sns_topic.alarms.arn
}

output "store_event_buses" {
  description = "Map of store id to that store's own Shopify partner event bus."
  value       = { for sid, s in var.stores : sid => s.event_bus }
}

output "store_queue_urls" {
  description = "Map of store id to its single SQS queue URL."
  value       = { for sid, q in aws_sqs_queue.main : sid => q.url }
}

output "store_ecs_services" {
  description = "Map of store id to its consumer ECS service name. Absent for a store whose consumer is off."
  value       = { for sid, svc in aws_ecs_service.consumer : sid => svc.name }
}

output "documentdb_security_group_id" {
  description = "Security group to attach to the manually-created DocumentDB cluster. Null when enable_mongodb is false."
  value       = one(aws_security_group.documentdb[*].id)
}

output "public_assets_prefix" {
  description = "Where to write sitemaps and feeds: this prefix of the assets bucket is what CloudFront serves."
  value       = local.enable_public_assets ? "s3://${aws_s3_bucket.assets.id}/${var.public_assets_prefix}/" : null
}

output "public_assets_domain" {
  description = "CloudFront domain serving the public assets. Point a CNAME at this if using a custom host."
  value       = one(aws_cloudfront_distribution.public_assets[*].domain_name)
}

output "oneshot_task_run_config" {
  description = "What the ECS console asks for when running a one-shot task definition: which cluster, which subnets, which security group."
  value = {
    cluster         = aws_ecs_cluster.this.name
    task_definition = aws_ecs_task_definition.sitemap.family
    launch_type     = "FARGATE"
    subnets         = aws_subnet.private[*].id
    security_group  = aws_security_group.ecs.id
    public_ip       = "DISABLED"
  }
}
