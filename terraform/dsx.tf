###############################################################################
# DSX dual-protocol mode — VPC plumbing (all gated on dsx_mode).
#
# The portal's NFSv3 server lives INSIDE the NFS server instance, in a network
# namespace at var.dsx_portal_ip on a veth link. From the host's point of view
# that works out of the box; from OTHER instances it needs the VPC to treat the
# server as a router for the portal CIDR. Three pieces:
#
#   1. a ROUTE: portal CIDR -> the server's ENI (clients' subnet route table);
#   2. source_dest_check = false on the server (set in nfs_backend.tf): EC2
#      normally drops traffic an instance sends/receives that isn't addressed
#      to/from its own IP — exactly what forwarding to a netns looks like;
#   3. SG openings for the v3 control plane: rpcbind (:111) and the PINNED
#      mountd port. (:2049 from the clients SG already exists for the main
#      export — SG rules are destination-IP-agnostic, so it covers the portal.)
#
# The portal services themselves are Ansible's job (roles/nfs_server/dsx.yml);
# this file only makes the namespace reachable.
###############################################################################

locals {
  dsx_enabled = var.dsx_mode && local.use_self_managed
}

# Route the portal CIDR at the server's ENI in the route table that serves the
# fleet subnet (public RT by default; the private RT when private_networking).
resource "aws_route" "dsx_portal" {
  count = local.dsx_enabled ? 1 : 0

  route_table_id         = var.private_networking ? aws_route_table.private[0].id : aws_route_table.harness.id
  destination_cidr_block = var.dsx_portal_cidr
  network_interface_id   = aws_instance.nfs_server[0].primary_network_interface_id
}

# NFSv3 control-plane ports into the server, from the clients SG only.
# rpcbind — not strictly needed once clients pass mountport=, kept for
# showmount/debugging; CIDR never widens beyond the client SG either way.
resource "aws_security_group_rule" "dsx_rpcbind" {
  count = local.dsx_enabled ? 1 : 0

  type                     = "ingress"
  description              = "DSX portal: rpcbind (NFSv3 portmapper) from clients"
  from_port                = 111
  to_port                  = 111
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nfs_server.id
  source_security_group_id = aws_security_group.clients.id
}

resource "aws_security_group_rule" "dsx_mountd" {
  count = local.dsx_enabled ? 1 : 0

  type                     = "ingress"
  description              = "DSX portal: pinned rpc.mountd (NFSv3 MNT) from clients"
  from_port                = var.dsx_mountd_port
  to_port                  = var.dsx_mountd_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nfs_server.id
  source_security_group_id = aws_security_group.clients.id
}
