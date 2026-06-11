###############################################################################
# Observability compute + persistent metrics storage.
#
# Principle 2 made concrete: the EBS volume (metrics) is a standalone resource
# with prevent_destroy and NO TestPlane tag, so it outlives every test cycle.
# The Prometheus/Grafana EC2 instance is count-gated on var.observability_running
# so obs-down tears the compute down to ~zero cost while the volume — and every
# metric on it — stays put for the next obs-up to re-attach.
###############################################################################

locals {
  ts = data.terraform_remote_state.harness.outputs

  # AL2023 image + network come from the test plane's state.
  subnet_id           = local.ts.subnet_id
  subnet_az           = local.ts.subnet_az
  observability_sg_id = local.ts.observability_sg_id

  # node_exporter scrape targets (:9100). Clients always; the self-managed NFS
  # server too when present. EFS has no host to scrape.
  client_targets = [for ip in local.ts.client_private_ips : "${ip}:9100"]
  # try(): Terraform omits null-valued outputs from state, so server_private_ip
  # is simply absent from the remote-state object when the backend is EFS.
  server_private_ip = try(local.ts.server_private_ip, null)
  server_targets    = local.server_private_ip != null ? ["${local.server_private_ip}:9100"] : []
  scrape_targets = concat(local.client_targets, local.server_targets)

  # Rendered as a YAML inline-sequence for prometheus.yml: 'a:9100','b:9100'
  scrape_targets_yaml = join(", ", [for t in local.scrape_targets : "'${t}'"])
}

# Reuse the same AL2023 image family as the rest of the harness.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

###############################################################################
# Persistent metrics volume — survives everything. prevent_destroy is the
# backstop; obs-down never targets it anyway (it's not gated on _running).
###############################################################################
resource "aws_ebs_volume" "metrics" {
  availability_zone = local.subnet_az
  size              = var.metrics_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-obs-metrics"
    Role = "observability-storage"
    # Deliberately NO TestPlane tag — this must never be swept by teardown.
  }

  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# On-demand observability compute. count flips with observability_running.
###############################################################################
resource "aws_instance" "prometheus" {
  count = var.observability_running ? 1 : 0

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.observability_instance_type
  key_name                    = var.ssh_key_name
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [local.observability_sg_id]
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    scrape_targets_yaml    = local.scrape_targets_yaml
    grafana_admin_password = var.grafana_admin_password
  })

  # The scrape-target list is baked into user_data, so when the fleet changes the
  # box MUST be rebuilt to pick up the new prometheus.yml. Without this, the AWS
  # provider updates user_data in state but never re-runs cloud-init (default is
  # user_data_replace_on_change = false), leaving Prometheus on stale targets.
  user_data_replace_on_change = true

  # Root needs headroom for the Prometheus + Grafana images; the AL2023 default
  # is too small and docker image extraction fails with "no space left".
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Recreate the box, not the data: changes to user-data replace the instance,
  # but the volume + attachment below re-establish the same metrics on boot.
  tags = {
    Name = "${var.project_name}-observability"
    Role = "observability"
  }
}

resource "aws_volume_attachment" "metrics" {
  count = var.observability_running ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.metrics.id
  instance_id = aws_instance.prometheus[0].id

  # On instance replacement, detach cleanly so the volume can re-attach to the
  # new box instead of erroring on a busy device.
  stop_instance_before_detaching = true
}
