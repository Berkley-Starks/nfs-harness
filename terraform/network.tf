###############################################################################
# VPC + networking
# Single public subnet is sufficient for a throwaway test harness. For a
# production-grade design you'd split public/private subnets and NAT; that's a
# deliberate simplification worth naming to an architect.
###############################################################################

resource "aws_vpc" "harness" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "harness" {
  vpc_id = aws_vpc.harness.id
  tags   = { Name = "${var.project_name}-igw" }
}

# Pick the first available AZ in the region so we don't hardcode one.
data "aws_availability_zones" "available" {
  state = "available"
}

# Public subnet: always present. Hosts the observability box, the NAT gateway,
# and — in the default public posture — the fleet itself.
resource "aws_subnet" "harness" {
  vpc_id                  = aws_vpc.harness.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

# Private subnet: only when private_networking. The fleet lands here with no
# public IPs; egress is via the NAT gateway below.
resource "aws_subnet" "private" {
  count                   = var.private_networking ? 1 : 0
  vpc_id                  = aws_vpc.harness.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project_name}-private-subnet" }
}

resource "aws_route_table" "harness" {
  vpc_id = aws_vpc.harness.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.harness.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "harness" {
  subnet_id      = aws_subnet.harness.id
  route_table_id = aws_route_table.harness.id
}

###############################################################################
# NAT egress for the private fleet (private_networking only). The private subnet
# has no route to the IGW; instead it routes 0.0.0.0/0 through a NAT gateway that
# lives in the public subnet, so the fleet can pull packages/images without being
# reachable from the internet.
###############################################################################
resource "aws_eip" "nat" {
  count  = var.private_networking ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "harness" {
  count         = var.private_networking ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.harness.id # NAT must sit in a public subnet
  tags          = { Name = "${var.project_name}-nat" }

  depends_on = [aws_internet_gateway.harness]
}

resource "aws_route_table" "private" {
  count  = var.private_networking ? 1 : 0
  vpc_id = aws_vpc.harness.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.harness[0].id
  }

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = var.private_networking ? 1 : 0
  subnet_id      = aws_subnet.private[0].id
  route_table_id = aws_route_table.private[0].id
}

locals {
  # Where the fleet (clients + server) actually lands. Private subnet when
  # hardened, the public subnet otherwise. The observability box always uses the
  # public subnet (aws_subnet.harness) so Grafana stays reachable.
  fleet_subnet_id = var.private_networking ? aws_subnet.private[0].id : aws_subnet.harness.id
  # CIDR the fleet sits in — used to scope the NFS export to the fleet only,
  # instead of exporting to the world (`*`).
  fleet_cidr = var.private_networking ? var.private_subnet_cidr : var.subnet_cidr
}

###############################################################################
# Security groups — least privilege between roles.
# Three SGs: clients, nfs-server, observability. Rules reference each other by
# SG id (not CIDR) wherever the traffic is intra-harness, so access is scoped
# to membership rather than to an IP range.
###############################################################################

# --- Client fleet SG -------------------------------------------------------
resource "aws_security_group" "clients" {
  name        = "${var.project_name}-clients"
  description = "NFS client fleet"
  vpc_id      = aws_vpc.harness.id

  # SSH for Ansible + hands-on debugging, restricted to your IP. Dropped entirely
  # in private mode, where access is via SSM (no inbound SSH anywhere).
  dynamic "ingress" {
    for_each = var.private_networking ? [] : [1]
    content {
      description = "SSH from admin"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
    }
  }

  egress {
    description = "All egress (clients need to mount NFS + pull packages/images)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-clients-sg" }
}

# --- NFS server SG ---------------------------------------------------------
# Used by BOTH the self-managed server and the EFS mount targets.
resource "aws_security_group" "nfs_server" {
  name        = "${var.project_name}-nfs-server"
  description = "NFS server / EFS mount target"
  vpc_id      = aws_vpc.harness.id

  # NFS (2049) only from the client fleet SG — not from a CIDR.
  ingress {
    description     = "NFS from client fleet"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.clients.id]
  }

  # SSH to the self-managed server (no-op for EFS), restricted to admin. Dropped
  # in private mode (SSM only).
  dynamic "ingress" {
    for_each = var.private_networking ? [] : [1]
    content {
      description = "SSH from admin"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
    }
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-nfs-server-sg" }
}

# --- Observability SG ------------------------------------------------------
# Prometheus scrapes node_exporter (:9100) on the fleet + server. We model the
# *scrape* direction here: the targets allow inbound 9100 from this SG.
resource "aws_security_group" "observability" {
  name        = "${var.project_name}-observability"
  description = "Prometheus / Grafana observability plane"
  vpc_id      = aws_vpc.harness.id

  # SSH + Grafana UI from admin.
  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Grafana UI from admin"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Prometheus UI from admin (target/debug visibility)"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All egress (scrape targets, pull packages)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-observability-sg" }
}

# node_exporter scrape rule: allow 9100 INTO clients from the observability SG.
resource "aws_security_group_rule" "clients_node_exporter" {
  type                     = "ingress"
  description              = "node_exporter scrape from observability"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clients.id
  source_security_group_id = aws_security_group.observability.id
}

# node_exporter scrape rule: allow 9100 INTO the nfs server from observability.
resource "aws_security_group_rule" "server_node_exporter" {
  type                     = "ingress"
  description              = "node_exporter scrape from observability"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nfs_server.id
  source_security_group_id = aws_security_group.observability.id
}
