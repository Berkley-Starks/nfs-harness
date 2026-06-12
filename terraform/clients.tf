###############################################################################
# Client fleet — the "NFS clients at scale" the harness exists to stand up.
#
# Cattle, not pets: identical nodes, count-driven by var.client_count, spot by
# default (var.client_capacity_type), all interruption-tolerant. Lose one and
# the run continues at N-1. The launch template carries the spot/on_demand
# decision exactly like the self-managed server does, so the two are flippable
# independently.
#
# Layer ownership: Terraform only stands the boxes up here. Ansible owns config
# (node_exporter, nfs-utils, mount, container runtime, workload) so the layers
# stay clean. user-data is therefore deliberately minimal — just enough to make
# the node reachable and self-describing for the Ansible inventory.
###############################################################################

locals {
  # Minimal bootstrap. AL2023 already ships python3 (Ansible needs it) and an
  # SSH daemon, so there is nothing to install here. We drop a marker file the
  # harness/inventory tooling can grep for to confirm a node finished booting.
  client_user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    echo "nfs-harness-client ready" > /etc/nfs-harness-role
  EOF
}

resource "aws_launch_template" "client" {
  name_prefix   = "${var.project_name}-client-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.client_instance_type
  key_name      = var.ssh_key_name
  user_data     = base64encode(local.client_user_data)

  vpc_security_group_ids = [aws_security_group.clients.id]

  # Encrypted root with modest headroom (the AL2023 default is ~2 GB, tight once
  # node_exporter + the workload container land).
  block_device_mappings {
    device_name = data.aws_ami.al2023.root_device_name
    ebs {
      volume_size           = var.client_root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Conditionally request spot. When on_demand, omit the spot block entirely so
  # the instance is launched as standard on-demand capacity.
  dynamic "instance_market_options" {
    for_each = var.client_capacity_type == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.project_name}-client"
      Role      = "client"
      TestPlane = "true" # marks this as disposable; the teardown guardrail keys on it
    }
  }
}

resource "aws_instance" "client" {
  # Gated on test_plane_enabled so the fleet drops to zero on `harness down`.
  count = var.test_plane_enabled ? var.client_count : 0

  launch_template {
    id      = aws_launch_template.client.id
    version = "$Latest"
  }

  subnet_id = local.fleet_subnet_id

  # SSM instance profile in private mode (enables agent registration + Ansible
  # over SSM); null in public mode.
  iam_instance_profile = local.fleet_instance_profile

  # Joins the server's cluster PG only when cluster_clients is set AND the client
  # type supports it (network-optimized, not the t3 default). null otherwise.
  placement_group = local.clients_placement_group

  tags = {
    Name      = "${var.project_name}-client-${count.index}"
    Role      = "client"
    TestPlane = "true"
  }
}
