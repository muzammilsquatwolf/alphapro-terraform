output "vpc_id" { value = module.alphapro.vpc_id }
output "alb_dns_name" { value = module.alphapro.alb_dns_name }
output "nat_gateway_public_ips" { value = module.alphapro.nat_gateway_public_ips }
output "ecs_cluster_name" { value = module.alphapro.ecs_cluster_name }
output "web_service" { value = module.alphapro.web_service }

output "db_endpoint" {
  value     = module.alphapro.db_endpoint
  sensitive = true
}
output "db_reader_endpoint" {
  value     = module.alphapro.db_reader_endpoint
  sensitive = true
}
output "valkey_endpoint" {
  value     = module.alphapro.valkey_endpoint
  sensitive = true
}
output "valkey_cache_endpoint" {
  value     = module.alphapro.valkey_cache_endpoint
  sensitive = true
}

output "alarm_sns_topic_arn" { value = module.alphapro.alarm_sns_topic_arn }
output "store_event_buses" { value = module.alphapro.store_event_buses }
output "store_queue_urls" { value = module.alphapro.store_queue_urls }
output "store_ecs_services" { value = module.alphapro.store_ecs_services }
