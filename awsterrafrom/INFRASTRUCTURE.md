# AlphaPro OMS — Infrastructure Documentation

> Complete inventory of the AWS infrastructure described in `terraform.json`
> (Terraform state file). This document records **every resource, attribute,
> and configuration value** found in the state so the stack can be understood,
> audited, and reproduced as Terraform code.

---

## 1. State metadata

| Field | Value |
|-------|-------|
| State format version | `4` |
| Terraform version | `1.5.7` |
| Serial | `202` |
| Lineage | `31737320-f069-3d99-12f9-d2b9f201c4d7` |
| Project | `alphapro` |
| Environment | `dev` |
| Managed by | `terraform` |
| AWS Region | `us-east-1` |
| AWS Account ID | `330929085533` |
| Resource blocks | `74` (≈95 individual resource instances) |

**Standard tags** applied to taggable resources:
`Project = alphapro`, `Environment = dev`, `ManagedBy = terraform`, plus a per-resource `Name`.

---

## 2. System overview

This is the **AlphaPro Order Management System (OMS)** — a Shopify → AWS
integration layer for two storefronts: **KSA** (Saudi Arabia) and **UAE**.

**Event flow:**

```
Shopify store (KSA / UAE)
        │  webhooks via Shopify→EventBridge partner integration
        ▼
EventBridge partner event bus (per store)
        │  6 rules filter on X-Shopify-Topic prefix
        ▼
SQS queues (inventory / orders / products, per store)  ──redrive──▶  Dead-letter queues
        │  poll
        ▼
ECS Fargate consumer services (6) ── + web/API service behind ALB
        │  read / write
        ▼
RDS PostgreSQL  +  ElastiCache Valkey (cache & celery broker)
```

Cross-cutting: VPC networking, IAM roles, Secrets Manager, CloudWatch logs +
alarms → SNS email alerting, application auto-scaling.

---

## 3. Networking

### 3.1 VPC
| Attribute | Value |
|-----------|-------|
| Name | `alphapro-dev-vpc` |
| CIDR block | `10.0.0.0/16` |
| DNS hostnames | enabled |
| DNS support | enabled |

### 3.2 Subnets (4 — across `us-east-1a` / `us-east-1b`)
| Name | CIDR | AZ | Tier | Public IP on launch |
|------|------|----|------|---------------------|
| `alphapro-dev-public-0` | `10.0.0.0/24` | us-east-1a | public | yes |
| `alphapro-dev-public-1` | `10.0.1.0/24` | us-east-1b | public | yes |
| `alphapro-dev-private-0` | `10.0.2.0/24` | us-east-1a | private | no |
| `alphapro-dev-private-1` | `10.0.3.0/24` | us-east-1b | private | no |

### 3.3 Gateways & routing
- **Internet Gateway** — attached to the VPC.
- **NAT Gateway** — single NAT in a public subnet, with a dedicated **Elastic IP (EIP)**.
- **Route tables:**
  - `public` → `0.0.0.0/0` via Internet Gateway
  - `private` → `0.0.0.0/0` via NAT Gateway
- **Route table associations (4)** — each subnet associated with its tier's route table.

### 3.4 Availability zones
- Data source `aws_availability_zones.available` — selects available AZs in the region.

---

## 4. Security groups (5)

| Resource | Name prefix | Purpose |
|----------|-------------|---------|
| `alb` | `alphapro-dev-alb-*` | Application Load Balancer |
| `ecs` | `alphapro-dev-ecs-*` | ECS Fargate tasks |
| `db` | `alphapro-dev-db-*` | RDS database |
| `valkey` | `alphapro-dev-valkey-*` | ElastiCache Valkey |
| `quicksight` | `alphapro-dev-quicksight-*` | QuickSight ENIs (BI access) |

### Security group rules (12)
| Rule | Type | Port | Protocol | Source |
|------|------|------|----------|--------|
| `db_from_ecs` | ingress | 5432 | tcp | ECS security group |
| `db_from_quicksight` | ingress | 5432 | tcp | QuickSight security group |
| `quicksight_egress_to_db` | egress | 5432 | tcp | DB security group |
| `db_public_ingress` (×N — `for_each` over allowed CIDRs) | ingress | 5432 | tcp | Office / static IPs (see below) |

**Allowed public DB CIDRs** (office / VPN egress IPs permitted to reach Postgres directly):
```
103.244.176.6/32
110.93.203.98/32
110.93.203.100/32
110.93.230.236/32
182.190.201.67/32
202.69.48.87/32
202.69.53.151/32
43.246.227.64/27
43.246.227.66/32
```
> These are environment-specific and a prime candidate for `.env` parameterization.

---

## 5. Compute — ECS on Fargate

### 5.1 Cluster
| Attribute | Value |
|-----------|-------|
| Name | `alphapro-dev` |
| Container Insights | enabled |
| Capacity providers | `FARGATE`, `FARGATE_SPOT` |
| Default strategy | `FARGATE` (base 1, weight 1) |

### 5.2 Task definitions (7)
All tasks: **CPU 256 / Memory 512**, network mode `awsvpc`, launch type `FARGATE`.
Container image (shared): `330929085533.dkr.ecr.us-east-1.amazonaws.com/alphapro-dev:latest`
Logs: driver `awslogs` → group `/ecs/alphapro-dev` (per-task `awslogs-stream-prefix`).

**Web/API task** (`web`)
- Container `web`, port mapping **8000/tcp**.
- Command runs Alembic migrations then `uvicorn main:app` on `$PORT`.
- Env: `AWS_REGION`, `CACHE_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND`, `DB_CONNECTION=postgresql`, `DB_DATABASE=alphapro`, `ENVIRONMENT=dev`, `INFRA_RELEASE_VERSION`, `PORT=8000`.
- Secrets (from Secrets Manager): `DB_HOST`, `DB_PASSWORD`, `DB_PORT`, `DB_USERNAME`.

**Consumer tasks (6)** — `for_each` over store × queue-type (`ksa`/`uae` × `inventory`/`orders`/`products`)
- No port mappings; command: `python -m app.consumers.<type>`.
- Env: `APP_URL`, `AWS_REGION`, `CACHE_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND`, `ENVIRONMENT`, `INFRA_RELEASE_VERSION`, `QUEUE_TYPE`, `QUEUE_URL`, `SHOPIFY_SQS_STRICT_HMAC=false`, `STORE_ID`, `STORE_NAME`.
- Secret: `DATABASE_URL`.
- Example values: `APP_URL=https://it-dev.alfapro.ai/`, `STORE_ID=ksa`, `STORE_NAME=AlphaPro KSA`.

### 5.3 ECS services (7)
| Service | Desired count | Load balancer | Public IP |
|---------|---------------|---------------|-----------|
| `alphapro-dev-web` | 1 | yes (ALB target group) | yes (public subnets) |
| `alphapro-dev-ksa-inventory-consumer` | 1 | no | no (private subnets) |
| `alphapro-dev-ksa-orders-consumer` | 1 | no | no |
| `alphapro-dev-ksa-products-consumer` | 1 | no | no |
| `alphapro-dev-uae-inventory-consumer` | 1 | no | no |
| `alphapro-dev-uae-orders-consumer` | 1 | no | no |
| `alphapro-dev-uae-products-consumer` | 1 | no | no |

### 5.4 Application Auto Scaling (7 targets + 7 policies)
All policies: **Target Tracking** on `ECSServiceAverageCPUUtilization`, target **70%**,
scale-out cooldown **60s**, scale-in cooldown **300s**, dimension `ecs:service:DesiredCount`.

| Service | Min | Max |
|---------|-----|-----|
| web | 1 | 10 |
| each consumer (×6) | 1 | 5 |

---

## 6. Load balancing

### 6.1 Application Load Balancer
| Attribute | Value |
|-----------|-------|
| Name | `alphapro-dev-alb` |
| Type | `application` |
| Scheme | internet-facing (not internal) |
| Idle timeout | 60s |
| Subnets | public subnets |
| Security group | `alb` |

### 6.2 Listener
- Port **80**, protocol **HTTP**, default action **forward** → target group.

### 6.3 Target group
| Attribute | Value |
|-----------|-------|
| Name | `alphapro-dev-tg` |
| Port / protocol | 8000 / HTTP |
| Target type | `ip` (Fargate) |
| Health check | path `/health`, matcher `200`, interval 30s |

---

## 7. Messaging

### 7.1 SQS queues (12 = 6 main + 6 DLQ)
Per store (`ksa`, `uae`) and type:

**Main queues**
| Queue | FIFO | Visibility timeout | Retention | Content dedup | Redrive → DLQ (maxReceiveCount) |
|-------|------|--------------------|-----------|---------------|---------------------------------|
| `alphapro-dev-<store>-inventory.fifo` | yes | 300s | 345600s (4d) | yes | yes (3) |
| `alphapro-dev-<store>-orders.fifo` | yes | 300s | 345600s (4d) | yes | yes (3) |
| `alphapro-dev-<store>-products` | no | 300s | 345600s (4d) | no | yes (3) |

**Dead-letter queues**
| Queue | FIFO | Visibility timeout | Retention |
|-------|------|--------------------|-----------|
| `alphapro-dev-<store>-inventory-dlq.fifo` | yes | 30s | 1209600s (14d) |
| `alphapro-dev-<store>-orders-dlq.fifo` | yes | 30s | 1209600s (14d) |
| `alphapro-dev-<store>-products-dlq` | no | 30s | 1209600s (14d) |

Max message size: **262144 bytes (256 KB)** for all queues.

**SQS queue policies (6)** — one per main queue, granting EventBridge permission to `SendMessage`.

### 7.2 EventBridge (6 rules + 6 targets)
Partner event buses:
- KSA: `aws.partner/shopify.com/347762098177/integration-layer-ksa-dev`
- UAE: `aws.partner/shopify.com/347762098177/integration-layer-uae-dev`

| Rule | Bus | Event pattern (detail-type `shopifyWebhook`) |
|------|-----|----------------------------------------------|
| `alphapro-dev-<store>-inventory` | store bus | `X-Shopify-Topic` prefix `inventory_levels/` |
| `alphapro-dev-<store>-orders` | store bus | `X-Shopify-Topic` prefix `orders/` |
| `alphapro-dev-<store>-products` | store bus | `X-Shopify-Topic` prefix `products/` |

**Targets:** each rule → its SQS queue. FIFO targets (inventory, orders) set a
`message_group_id`; products (standard) does not.

---

## 8. Data stores

### 8.1 RDS — PostgreSQL
| Attribute | Value |
|-----------|-------|
| Engine | PostgreSQL `17.6` |
| Instance class | `db.t3.micro` |
| Allocated / max storage | 20 GB / 100 GB (autoscaling) |
| Storage type | `gp2`, encrypted |
| Multi-AZ | no |
| Port | 5432 |
| DB name | `alphapro` |
| Master username | `alphapro_admin` |
| Publicly accessible | **yes** (restricted by SG to allowed CIDRs) |
| Backup retention | 1 day |
| Skip final snapshot | yes |
| Deletion protection | no |
| Subnet group | `aws_db_subnet_group` (private subnets) |

**DB parameter group** — family `postgres17`:
| Parameter | Value |
|-----------|-------|
| `log_connections` | 1 |
| `log_disconnections` | 1 |
| `log_lock_waits` | 1 |
| `log_min_duration_statement` | 1000 (ms) |
| `pg_stat_statements.track` | all |
| `shared_preload_libraries` | pg_stat_statements |

### 8.2 ElastiCache — Valkey (2 replication groups)
| Replication group | Node type | Engine | Port | Nodes | Failover | At-rest enc | Transit enc |
|-------------------|-----------|--------|------|-------|----------|-------------|-------------|
| `alphapro-dev-valkey` | cache.t3.micro | valkey 8.0 | 6379 | 1 | no | yes | yes |
| `alphapro-dev-valkey-cache` | cache.t3.micro | valkey 8.0 | 6380 | 1 | no | yes | yes |

- `alphapro-dev-valkey` (6379) → Celery broker / result backend (`CELERY_*` URLs).
- `alphapro-dev-valkey-cache` (6380) → application cache (`CACHE_URL`).
- Both use `rediss://` (TLS). Subnet group: `aws_elasticache_subnet_group` (private subnets).

---

## 9. Secrets & IAM

### 9.1 Secrets Manager (2 secrets + 1 version + 1 random password)
| Secret | Recovery window | Contents |
|--------|-----------------|----------|
| `alphapro/dev/database` | 0 (immediate delete) | keys: `DATABASE_URL`, `dbname`, `engine`, `host`, `password`, `port`, `username` |
| `alphapro/dev/shopify` | 0 | Shopify credentials |

- **`random_password`** — length 32, no special chars → generates the DB master password,
  stored in the `database` secret version.

### 9.2 IAM roles (2)
Both assume role for `ecs-tasks.amazonaws.com`.
- **`alphapro-dev-ecs-execution`** — task execution role.
- **`alphapro-dev-ecs-task`** — task (application) role.

### 9.3 IAM policies (2) & attachments (3)
**`alphapro-dev-ecs-secrets`** — `secretsmanager:GetSecretValue` on the database & shopify secret ARNs.

**`alphapro-dev-ecs-task`**:
- SQS: `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes`, `GetQueueUrl`, `ChangeMessageVisibility` on `arn:aws:sqs:*:*:alphapro-dev-*`.
- EventBridge: `events:PutEvents` on `arn:aws:events:*:*:event-bus/alphapro-dev-*`.
- Logs: `CreateLogStream`, `PutLogEvents` on `*`.

**Attachments:**
1. execution role ← AWS managed `AmazonECSTaskExecutionRolePolicy`
2. execution role ← `alphapro-dev-ecs-secrets`
3. task role ← `alphapro-dev-ecs-task`

Data source: `aws_iam_policy_document.ecs_assume_role`.

---

## 10. Observability

### 10.1 CloudWatch Logs
- Log group `/ecs/alphapro-dev`, retention **30 days**.

### 10.2 SNS
- Topic `alphapro-dev-alarms`.
- Subscription: **email** → `muzammal.saeed@squatwolf.com`.

### 10.3 CloudWatch metric alarms (18 = 3 types × 6 services)
All alarms notify the `alphapro-dev-alarms` SNS topic.

| Alarm (per store/type) | Metric | Namespace | Stat | Condition | Period × Evals |
|------------------------|--------|-----------|------|-----------|----------------|
| `*-dlq-not-empty` | ApproximateNumberOfMessagesVisible | AWS/SQS | Sum | `> 0` | 60s × 1 |
| `*-no-running-tasks` | RunningTaskCount | ECS/ContainerInsights | Average | `< 1` | 60s × 2 |
| `*-queue-depth` | ApproximateNumberOfMessagesVisible | AWS/SQS | Average | `> 1000` | 300s × 2 |

(6 services × 3 alarm types = 18 alarms.)

---

## 11. Outputs

| Output | Sensitive | Description |
|--------|-----------|-------------|
| `alarm_sns_topic_arn` | no | ARN of the alarms SNS topic |
| `alb_dns_name` | no | Public DNS of the ALB |
| `db_endpoint` | **yes** | RDS endpoint `host:5432` |
| `ecs_cluster_name` | no | `alphapro-dev` |
| `store_ecs_services` | no | Map: store → {inventory, orders, products} consumer service names |
| `store_event_buses` | no | Map: store → partner event bus ARN |
| `store_queue_urls` | no | Map: store → {inventory, orders, products} queue URLs |
| `valkey_cache_endpoint` | **yes** | Cache Valkey primary endpoint |
| `valkey_endpoint` | **yes** | Broker Valkey primary endpoint |
| `vpc_id` | no | VPC ID |
| `web_service` | no | Web ECS service name |

---

## 12. Complete resource inventory (74 blocks)

| # | Type | Name | Count |
|---|------|------|-------|
| 1 | aws_vpc | this | 1 |
| 2 | aws_subnet | public / private | 4 |
| 3 | aws_internet_gateway | this | 1 |
| 4 | aws_nat_gateway | this | 1 |
| 5 | aws_eip | nat | 1 |
| 6 | aws_route_table | public / private | 2 |
| 7 | aws_route_table_association | public / private | 4 |
| 8 | aws_security_group | alb / ecs / db / valkey / quicksight | 5 |
| 9 | aws_security_group_rule | db & quicksight rules | 12 |
| 10 | aws_db_subnet_group | this | 1 |
| 11 | aws_db_parameter_group | this | 1 |
| 12 | aws_db_instance | this | 1 |
| 13 | aws_elasticache_subnet_group | this | 1 |
| 14 | aws_elasticache_replication_group | valkey / valkey-cache | 2 |
| 15 | random_password | db | 1 |
| 16 | aws_secretsmanager_secret | database / shopify | 2 |
| 17 | aws_secretsmanager_secret_version | database | 1 |
| 18 | aws_ecs_cluster | this | 1 |
| 19 | aws_ecs_cluster_capacity_providers | this | 1 |
| 20 | aws_ecs_task_definition | web / consumer | 7 |
| 21 | aws_ecs_service | web / consumers | 7 |
| 22 | aws_appautoscaling_target | web / consumer | 7 |
| 23 | aws_appautoscaling_policy | web_cpu / consumer_cpu | 7 |
| 24 | aws_lb | this | 1 |
| 25 | aws_lb_listener | http | 1 |
| 26 | aws_lb_target_group | web | 1 |
| 27 | aws_sqs_queue | main / dlq | 12 |
| 28 | aws_sqs_queue_policy | eventbridge | 6 |
| 29 | aws_cloudwatch_event_rule | per store/type | 6 |
| 30 | aws_cloudwatch_event_target | per store/type | 6 |
| 31 | aws_cloudwatch_log_group | ecs | 1 |
| 32 | aws_cloudwatch_metric_alarm | dlq / tasks / depth | 18 |
| 33 | aws_sns_topic | alarms | 1 |
| 34 | aws_sns_topic_subscription | email | 1 |
| 35 | aws_iam_role | execution / task | 2 |
| 36 | aws_iam_policy | secrets / task | 2 |
| 37 | aws_iam_role_policy_attachment | 3 attachments | 3 |
| 38 | aws_iam_policy_document (data) | ecs_assume_role | 1 |
| 39 | aws_availability_zones (data) | available | 1 |

---

## 13. Values to parameterize (for dev/prod `.env` separation)

When reproducing this as multi-environment Terraform, the following differ per
environment and should be externalized into `.env` / variables:

- `project` (`alphapro`), `environment` (`dev` / `prod`), `aws_region`, `aws_account_id`
- `vpc_cidr`, subnet CIDRs, AZ count
- `allowed_db_cidrs` (office IP list)
- ECS: image tag / `INFRA_RELEASE_VERSION`, CPU/memory, desired counts, min/max scaling
- RDS: instance class, storage, multi-AZ, backup retention, deletion protection, publicly_accessible
- ElastiCache: node type, failover, number of clusters
- Stores map: `{ ksa = {...}, uae = {...} }` with `store_name`, `app_url`, partner event bus ARNs
- `APP_URL`, `SHOPIFY_SQS_STRICT_HMAC`
- Alarm thresholds (queue depth, etc.) and SNS alert email
- Log retention, Container Insights toggle
- **Secrets** (DB password is generated; Shopify creds supplied out-of-band — never commit)
