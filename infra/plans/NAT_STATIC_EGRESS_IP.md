# Static Outbound IPs for ECS Services

**Status: Implemented.** This describes a completed change (`nat_gateway_multi_az` variable, `web` service moved to private subnets, `nat_gateway_public_ips` output) — kept here as a record of why the NAT/subnet layout looks the way it does, not as a pending proposal.

## Context

Third-party systems need to whitelist AlphaPro OMS's outbound IP addresses, but ECS Fargate task public IPs are ephemeral by nature — they change on every deployment, task restart, or scaling event. Whitelisting against them today would break silently the next time a task cycles.

Investigation of the current stack (`infra/modules/alphapro/`) found the fix is narrower than "build new infrastructure" — most of the mechanism already exists, just applied inconsistently:

- **`consumer` services (12 per environment) already egress through a static IP.** They run in private subnets with `assign_public_ip = false`, routing through the single NAT Gateway's Elastic IP (`network.tf`). This part already satisfies the requirement today.
- **The `web` service does not.** It ran in the *public* subnets with `assign_public_ip = true` — it got an ephemeral public IP directly on its own Fargate task ENI, bypassing NAT entirely. This IP changed on every task replacement. This was the actual gap, and it's also the exact anti-pattern the requirement calls out ("avoid depending on individual ECS task public IPs").

Fargate `awsvpc` tasks cannot have a static Elastic IP attached directly to a task ENI (unlike EC2) — NAT Gateway + EIP, applied at the subnet/routing level, is the only AWS-native mechanism for a stable egress IP for Fargate. This is also why the fix is structural (subnet placement) rather than per-service configuration, and why it automatically covers any future consumer services added later (e.g. a 5th store) with no further changes.

Neither `dev` nor `prod` had been applied yet at the time of this change (no state file, no backend configured in either environment) — confirmed by direct inspection. This landed as a pre-deployment design fix, not a live migration.

**Decision made with the user:** both environments get exactly 1 static egress IP (single NAT Gateway, no AZ redundancy) — cheapest, simplest, one IP to hand the third party per environment. The user explicitly declined the AZ-redundant option (which would require 2 IPs per environment — AWS does not allow multiple NAT Gateways to share one EIP, so multi-AZ HA and a single IP are mutually exclusive; there's no way around this constraint). The design still builds in a toggle for later, at zero cost today, so upgrading either environment to HA in the future doesn't require restructuring or produce a new IP for the gateway that's already there.

## Approach

### 1. Fix the actual gap — move `web` into private subnets

In `infra/modules/alphapro/ecs.tf`, `aws_ecs_service.web`'s `network_configuration` block changed from:
```hcl
subnets          = aws_subnet.public[*].id
security_groups  = [aws_security_group.ecs.id]
assign_public_ip = true
```
to the exact same shape `aws_ecs_service.consumer` already uses:
```hcl
subnets          = aws_subnet.private[*].id
security_groups  = [aws_security_group.ecs.id]
assign_public_ip = false
```

**No security group changes needed.** The ALB→ECS rule in `security.tf` (`aws_security_group.ecs`'s ingress) is keyed by security group reference (`security_groups = [aws_security_group.alb.id]`), not by CIDR or subnet — and the target group uses `target_type = "ip"` (`alb.tf`), which registers task ENI IPs directly regardless of subnet tier. Every VPC has an implicit local route between its own subnets, so the ALB (staying in public subnets, unchanged) continues reaching `web` tasks in private subnets exactly as it reaches any other private-subnet resource. Inbound webhook traffic terminates at the ALB over this local route and never touches NAT — this change only affects traffic `web` itself initiates outbound (e.g. calling Shopify's API).

Every ECS service in the stack — web and all 12 consumers — now egresses exclusively through the NAT Gateway, eliminating the only ephemeral-IP path in the stack.

### 2. NAT topology built as a toggle, default off (1 IP everywhere)

Rather than hardcoding "1 NAT Gateway" permanently, it's a variable so a future upgrade to AZ-redundant NAT (if ever needed) is additive — the existing IP stays valid, only a second gateway/IP gets added — instead of requiring a rewrite. This costs nothing today: with the toggle off, exactly 1 NAT Gateway and 1 EIP are created, identical to what existed before this change.

In `infra/modules/alphapro/network.tf`, the NAT/EIP/private-route-table resources are `for_each`, keyed by a **stable string index** (`"0"`, `"1"`, ...) rather than bare `count` — this is what makes a future toggle additive rather than disruptive (count-based indices reshuffle when the collection size changes; string-keyed `for_each` doesn't):

- `aws_eip.nat` — `for_each` over `["0"]` when the toggle is off, `["0", "1"]` when on (one per AZ)
- `aws_nat_gateway.this` — same `for_each`, each one placed in the matching-index public subnet
- `aws_route_table.private` — same `for_each`, one per key, each routing `0.0.0.0/0` to its own NAT Gateway
- `aws_route_table_association.private` — stays `count`-based over the private subnets themselves (which subnets exist doesn't change), but resolves which route table each one associates to based on the toggle

No changes to `aws_route_table.public` or its associations — public subnets always route via the Internet Gateway regardless of NAT topology.

```hcl
variable "nat_gateway_multi_az" {
  description = "One NAT Gateway + Elastic IP per AZ (AZ-redundant, N static egress IPs) instead of a single shared one (1 static IP, no AZ redundancy). More IPs means more addresses to hand third parties for whitelisting."
  type        = bool
  default     = false
}
```
Default `false` in both `dev` and `prod` `.env` files, per the decision above — both environments get 1 static IP, no AZ redundancy.

### 3. Static IP(s) surfaced as a proper output

`nat_gateway_public_ips` (map keyed by the same index strings) on `infra/modules/alphapro/outputs.tf`, passed through both `infra/environments/dev/outputs.tf` and `infra/environments/prod/outputs.tf`, following the pattern already used for `alb_dns_name`. Read it with `terraform output -json nat_gateway_public_ips` — the stable place to get the IP(s) to hand the third party, rather than hunting through the console after every apply.

## Files touched

| File | Change |
|---|---|
| `infra/modules/alphapro/variables.tf` | Added `nat_gateway_multi_az` bool, default `false` |
| `infra/modules/alphapro/network.tf` | Converted `aws_eip.nat`, `aws_nat_gateway.this`, `aws_route_table.private` to `for_each`; updated `aws_route_table_association.private` to resolve the right table |
| `infra/modules/alphapro/ecs.tf` | `aws_ecs_service.web` network_configuration → private subnets, `assign_public_ip = false` |
| `infra/modules/alphapro/outputs.tf` | Added `nat_gateway_public_ips` output |
| `infra/environments/{dev,prod}/variables.tf` | Added pass-through `nat_gateway_multi_az` variable (identical in both) |
| `infra/environments/{dev,prod}/main.tf` | Wired `nat_gateway_multi_az = var.nat_gateway_multi_az` into the `module "alphapro"` call |
| `infra/environments/{dev,prod}/outputs.tf` | Added `nat_gateway_public_ips` output pass-through |
| `infra/environments/dev/.env` + `.env.example` | Added `TF_VAR_nat_gateway_multi_az=false` |
| `infra/environments/prod/.env` + `.env.example` | Added `TF_VAR_nat_gateway_multi_az=false` |

No changes to `security.tf` or `alb.tf` — this doesn't touch ingress paths, and the wide-open `0.0.0.0/0` egress security group rule is intentionally left as-is (the third party's whitelisting is enforced at the NAT Gateway's Elastic IP / AWS network edge, independent of what the ECS security group's own egress rule permits; tightening it doesn't make the static-IP mechanism more correct). Egress hardening and adding an HTTPS/443 listener to the ALB (there is currently only HTTP:80) are both pre-existing, unrelated gaps — noted here so they aren't mistaken for something this change was supposed to fix.

Since neither environment had any Terraform state at the time of this change, no `moved` blocks were needed and there was no live task replacement to sequence carefully — it landed as a normal first `apply` for both environments.

## Verification

1. `terraform fmt` + `terraform validate` in both `infra/environments/dev` and `infra/environments/prod` — passed clean.
2. `terraform plan` in each environment before applying — confirm the plan shows: `aws_ecs_service.web` created/updated with the private-subnet network configuration, exactly 1 `aws_nat_gateway`/`aws_eip` (not 2, since `nat_gateway_multi_az=false`), and the `nat_gateway_public_ips` output present.
3. After `apply`, confirm from a running `web` task (e.g. via `aws ecs execute-command` or by triggering an outbound call from the app) that its egress IP matches `terraform output nat_gateway_public_ips` — the same address the consumer services already egress through.
4. Confirm ALB→web connectivity is unaffected: `curl http://<alb_dns_name>/health` still returns 200 after the change, proving inbound traffic through the ALB into the now-private-subnet `web` tasks still works.
