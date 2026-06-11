###############################################################################
# Cluster placement group
#
# A cluster placement group packs instances onto low-latency, high-bandwidth
# hardware within ONE Availability Zone (the harness already pins a single AZ in
# network.tf). It is the second half of the "take the network out of the
# experiment" fix: the server runs on a network-optimized instance (see
# server_instance_type) AND sits in a cluster PG so its path to the clients is
# consistent run to run.
#
# Gated on test_plane_enabled so it disappears with the rest of the
# system-under-test on `harness down`. Clients join only when cluster_clients is
# set (and they're a supported, non-burstable type) — see variables.tf.
###############################################################################

resource "aws_placement_group" "cluster" {
  count    = var.test_plane_enabled && var.enable_placement_group ? 1 : 0
  name     = "${var.project_name}-cluster"
  strategy = "cluster"

  tags = { Name = "${var.project_name}-cluster-pg" }
}

locals {
  # Resolved PG name (or null) for the server and clients respectively. null
  # omits the placement_group argument entirely, so the instance lands wherever
  # AWS puts it.
  server_placement_group  = var.enable_placement_group ? one(aws_placement_group.cluster[*].name) : null
  clients_placement_group = var.enable_placement_group && var.cluster_clients ? one(aws_placement_group.cluster[*].name) : null
}
