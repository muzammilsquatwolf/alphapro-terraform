###############################################################################
# VPC peering to the account's DEFAULT VPC.
#
# Lets instances in the default VPC reach things in this one — DocumentDB in
# particular, which lives here and is managed by hand.
#
# Four things have to line up, and the fourth is the one that is usually
# missed:
#
#   1. the peering connection itself
#   2. a route on BOTH sides, in EVERY route table behind which a reachable
#      ENI can land (packets that leave without a return route just vanish,
#      with nothing logged)
#   3. a security group rule admitting the peer CIDR
#   4. DNS resolution across the connection — without it, a DocumentDB
#      endpoint resolves to its PUBLIC address from the peer VPC and the
#      connection fails despite the routes being correct
#
# The default VPC is discovered rather than configured: there is exactly one
# per region and hardcoding its id would be a value that differs per account
# for no reason.
#
# Peering is non-transitive. This connects the default VPC to this one and to
# nothing beyond it.
###############################################################################

data "aws_vpc" "default" {
  count   = var.enable_default_vpc_peering ? 1 : 0
  default = true
}

data "aws_route_tables" "default" {
  count  = var.enable_default_vpc_peering ? 1 : 0
  vpc_id = data.aws_vpc.default[0].id
}

resource "aws_vpc_peering_connection" "default" {
  count = var.enable_default_vpc_peering ? 1 : 0

  vpc_id      = aws_vpc.this.id
  peer_vpc_id = data.aws_vpc.default[0].id

  # Same account and same region, so no separate accept step.
  auto_accept = true

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-to-default" })
}

# Both halves, or the endpoint resolves to a public address from the peer side.
resource "aws_vpc_peering_connection_options" "default" {
  count = var.enable_default_vpc_peering ? 1 : 0

  vpc_peering_connection_id = aws_vpc_peering_connection.default[0].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# This side: every private route table reaches the default VPC.
resource "aws_route" "private_to_default" {
  for_each = var.enable_default_vpc_peering ? aws_route_table.private : {}

  route_table_id            = each.value.id
  destination_cidr_block    = data.aws_vpc.default[0].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.default[0].id
}

# The public route table too, and this is not optional housekeeping: the
# DocumentDB cluster is created by hand and its subnet group sits in the
# PUBLIC subnets, so the cluster's ENIs route through this table rather than
# the private one. Without this route a reply to the default VPC falls through
# to 0.0.0.0/0 and the internet gateway, which silently discards RFC1918
# traffic — the TCP handshake hangs instead of being refused, DNS still
# resolves correctly, and neither side logs anything. Routing the peer CIDR
# explicitly keeps the reply on the peering connection where the request came
# from.
#
# This stays correct if the cluster is ever moved into the private subnets;
# the route is simply unused there.
resource "aws_route" "public_to_default" {
  count = var.enable_default_vpc_peering ? 1 : 0

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = data.aws_vpc.default[0].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.default[0].id
}

# The other side. These route tables belong to the default VPC, which this
# stack does not otherwise manage — the route is additive and scoped to this
# VPC's CIDR, so it cannot affect anything already running there.
resource "aws_route" "default_to_this" {
  for_each = var.enable_default_vpc_peering ? toset(data.aws_route_tables.default[0].ids) : []

  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.default[0].id
}

# A CIDR rule, not a security group reference. Cross-VPC SG references do work
# within a region, but that would mean naming a specific group in a VPC this
# stack does not manage — and the default VPC's groups are not ours to depend
# on.
resource "aws_security_group_rule" "documentdb_from_default_vpc" {
  count = var.enable_default_vpc_peering && var.enable_mongodb ? 1 : 0

  type              = "ingress"
  description       = "DocumentDB from the default VPC over peering"
  from_port         = var.documentdb_port
  to_port           = var.documentdb_port
  protocol          = "tcp"
  security_group_id = aws_security_group.documentdb[0].id
  cidr_blocks       = [data.aws_vpc.default[0].cidr_block]
}
