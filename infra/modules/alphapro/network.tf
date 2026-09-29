data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.default_tags, {
    Name = "${local.name_prefix}-public-${count.index}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.default_tags, {
    Name = "${local.name_prefix}-private-${count.index}"
    Tier = "private"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-igw" })
}

locals {
  # One NAT Gateway (index "0") by default; one per AZ ("0", "1", ...) when
  # nat_gateway_multi_az is on. Keyed by stable string index, not bare count,
  # so flipping this later only adds a gateway/EIP — it never reshuffles or
  # replaces the one(s) already in use (and already whitelisted downstream).
  nat_gateway_keys = var.nat_gateway_multi_az ? [for i, s in aws_subnet.public : tostring(i)] : ["0"]
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_gateway_keys)

  domain = "vpc"

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-nat-eip-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_gateway_keys)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[tonumber(each.key)].id

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table" "private" {
  for_each = toset(local.nat_gateway_keys)

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[each.key].id
  }

  tags = merge(local.default_tags, { Name = "${local.name_prefix}-private-rt-${each.key}" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id = aws_subnet.private[count.index].id
  # Multi-AZ: each private subnet routes through its own AZ's NAT Gateway.
  # Single-NAT (default): every private subnet shares route table "0".
  route_table_id = aws_route_table.private[var.nat_gateway_multi_az ? tostring(count.index) : "0"].id
}
