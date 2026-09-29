variable "aws_region" {
  description = "Region the state buckets and lock table live in. Must match the `region` in each environment's backend.hcl."
  type        = string
  default     = "ap-southeast-1"
}

variable "state_bucket_names" {
  description = <<-EOT
    One S3 state bucket per environment. Kept separate (rather than one shared
    bucket with different key prefixes) so a mistake against one environment's
    state can't reach the other's. Must match the `bucket` value in each
    environment's backend.hcl.
  EOT
  type        = list(string)
  default = [
    "squatwolf-alphapro-dev-tfstate",
    "squatwolf-alphapro-prod-tfstate",
  ]
}

variable "lock_table_name" {
  description = <<-EOT
    DynamoDB table for state locking. One table serves every environment — the
    lock key includes the bucket name, so dev and prod locks never collide.
    Must match the `dynamodb_table` value in each environment's backend.hcl.
  EOT
  type        = string
  default     = "squatwolf-alphapro-terraform-locks"
}
