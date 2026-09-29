output "state_buckets" {
  description = "State bucket names — these are the `bucket` values for each environment's backend.hcl."
  value       = [for b in aws_s3_bucket.state : b.id]
}

output "lock_table" {
  description = "Lock table name — the `dynamodb_table` value for every environment's backend.hcl."
  value       = aws_dynamodb_table.locks.name
}

output "region" {
  description = "Region these live in — the `region` value for every environment's backend.hcl."
  value       = var.aws_region
}
