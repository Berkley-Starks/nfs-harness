###############################################################################
# Selectable NFS backend
#
# Pattern: each backend's resources use `count` gated on var.nfs_backend, so
# exactly one backend is materialized. A single output (nfs_endpoint, in
# outputs.tf) resolves to whichever was built, so the client fleet mounts the
# same way regardless of choice. This is the EFS-vs-self-managed tradeoff turned
# into a runtime toggle.
###############################################################################

locals {
  # Both gated on test_plane_enabled so `harness down` (flip false + apply)
  # tears the backend down with the rest of the system-under-test.
  use_efs          = var.nfs_backend == "efs" && var.test_plane_enabled
  use_self_managed = var.nfs_backend == "self_managed" && var.test_plane_enabled
}

###############################################################################
# Option A: EFS (managed, serverless storage)
###############################################################################

resource "aws_efs_file_system" "this" {
  count          = local.use_efs ? 1 : 0
  creation_token = "${var.project_name}-efs"
  encrypted      = true

  tags = { Name = "${var.project_name}-efs" }
}

resource "aws_efs_mount_target" "this" {
  count           = local.use_efs ? 1 : 0
  file_system_id  = aws_efs_file_system.this[0].id
  subnet_id       = aws_subnet.harness.id
  security_groups = [aws_security_group.nfs_server.id]
}

###############################################################################
# Option B: self-managed NFS server on EC2
###############################################################################

# AL2023 AMI lookup is shared (clients need it for any backend); see data.tf.

# user-data: install nfs server, export a directory. Minimal on purpose; Ansible
# will own deeper config once that layer lands.
locals {
  server_user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y nfs-utils
    mkdir -p /srv/nfs/share
    chmod 777 /srv/nfs/share
    echo "/srv/nfs/share *(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    systemctl enable --now nfs-server
    exportfs -ra
  EOF
}

# Launch template carries the spot/on_demand decision for the server.
resource "aws_launch_template" "nfs_server" {
  count         = local.use_self_managed ? 1 : 0
  name_prefix   = "${var.project_name}-nfs-server-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.server_instance_type
  key_name      = var.ssh_key_name
  user_data     = base64encode(local.server_user_data)

  vpc_security_group_ids = [aws_security_group.nfs_server.id]

  # Conditionally request spot. When on_demand, omit the spot block entirely.
  dynamic "instance_market_options" {
    for_each = var.server_capacity_type == "spot" ? [1] : []
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
      Name      = "${var.project_name}-nfs-server"
      Role      = "nfs-server"
      TestPlane = "true"
    }
  }
}

resource "aws_instance" "nfs_server" {
  count = local.use_self_managed ? 1 : 0

  launch_template {
    id      = aws_launch_template.nfs_server[0].id
    version = "$Latest"
  }

  subnet_id = aws_subnet.harness.id

  # Low-latency, low-variance path to the clients. null when the PG is disabled.
  placement_group = local.server_placement_group

  tags = {
    Name      = "${var.project_name}-nfs-server"
    Role      = "nfs-server"
    TestPlane = "true"
  }
}
