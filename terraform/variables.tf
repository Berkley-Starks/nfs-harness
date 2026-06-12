###############################################################################
# Core / environment
###############################################################################

variable "region" {
  description = "AWS region to deploy the harness into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile. Default to the least-privilege user; flip to nfs-harness-broad if a tight policy is missing a permission."
  type        = string
  default     = "nfs-harness-tight"
}

variable "project_name" {
  description = "Short name used for tagging and resource naming."
  type        = string
  default     = "nfs-harness"
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for SSH access to instances."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH in (your IP /32). Do NOT leave as 0.0.0.0/0."
  type        = string
  # Example: "203.0.113.4/32". Intentionally no permissive default.
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the harness VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet (obs box, NAT gateway, and the fleet in public mode)."
  type        = string
  default     = "10.42.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private fleet subnet (used only when private_networking = true)."
  type        = string
  default     = "10.42.2.0/24"
}

###############################################################################
# NFS backend selection
###############################################################################

variable "test_plane_enabled" {
  description = "Master switch for the disposable test plane (NFS backend + client fleet). bin/harness down flips this false and applies, destroying the system-under-test while the VPC, SGs, and teardown guardrail persist. up flips it back true."
  type        = bool
  default     = true
}

variable "nfs_backend" {
  description = "Which NFS backend to provision: 'efs' (managed) or 'self_managed' (EC2 NFS server)."
  type        = string
  default     = "efs"

  validation {
    condition     = contains(["efs", "self_managed"], var.nfs_backend)
    error_message = "nfs_backend must be either 'efs' or 'self_managed'."
  }
}

###############################################################################
# Capacity type — independently flippable for server vs clients.
# Clients are textbook spot (cattle). Server is more pet: spot is fine for
# repro/load tests, flip to on_demand for clean uninterrupted benchmark runs.
###############################################################################

variable "client_capacity_type" {
  description = "Purchase option for the client fleet: 'spot' or 'on_demand'."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "on_demand"], var.client_capacity_type)
    error_message = "client_capacity_type must be 'spot' or 'on_demand'."
  }
}

variable "server_capacity_type" {
  description = "Purchase option for the self-managed NFS server: 'spot' or 'on_demand'."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "on_demand"], var.server_capacity_type)
    error_message = "server_capacity_type must be 'spot' or 'on_demand'."
  }
}

###############################################################################
# Instance sizing / fleet scale
###############################################################################

variable "client_count" {
  description = "Number of NFS client nodes in the fleet (the 'at scale' knob)."
  type        = number
  default     = 3

  validation {
    condition     = var.client_count >= 1 && var.client_count <= 100
    error_message = "client_count must be between 1 and 100."
  }
}

variable "client_instance_type" {
  description = "Instance type for client load generators. Default is a network-optimized (c5n) type with guaranteed bandwidth and cluster-PG support. Do NOT use burstable (t3/t2): the NIC allowance drains under sustained load (watch the ENA bw_out_allowance_exceeded panel), adding credit-dependent, per-node tail latency that makes results a function of wall-clock time. t3.small is fine only for cheap smoke tests where throughput numbers don't matter."
  type        = string
  default     = "c5n.large"
}

variable "server_instance_type" {
  description = "Instance type for the self-managed NFS server (when nfs_backend = self_managed). Default is m5dn.large: enhanced networking ('n') AND local NVMe instance store ('d'). The local NVMe (used when server_use_instance_store = true) takes EBS out of the data path entirely — the c5n family has the big NIC but no local disk, so its EBS baseline (0.65 Gbit/s on c5n.large) caps the export. Never benchmark on burstable (t3/t2), where the network baseline collapses once burst credits drain."
  type        = string
  default     = "m5dn.large"
}

variable "server_use_instance_store" {
  description = "true = export rides on the server's LOCAL NVMe instance store (bypasses EBS, removing the instance-EBS-bandwidth cap that bound the gp3 run; requires a 'd'-family type like m5dn/c5d/i3en). false = export rides on the dedicated provisioned-throughput EBS volume below (works on any type, but is bounded by the instance's EBS pipe). Instance-store is EPHEMERAL — fine here because the test data is throwaway and the fleet is create/destroy, never stop/start."
  type        = bool
  default     = true
}

variable "server_root_volume_gb" {
  description = "Root volume size (GB) for the self-managed NFS server. The export now lives on a dedicated data volume (see below), so the root only holds the OS — keep it modest."
  type        = number
  default     = 30
}

###############################################################################
# NFS server EXPORT data volume (the EBS path).
#
# Used ONLY when server_use_instance_store = false. With instance-store on (the
# default), these are ignored and the export rides the local NVMe instead.
#
# When in use: the export (/srv/nfs/share) gets its OWN volume rather than riding
# on the root disk — so its throughput/IOPS are a documented, provisioned variable
# instead of the gp3 *baseline* (125 MB/s, 3k IOPS). Note this still sits behind
# the instance's EBS bandwidth pipe (e.g. ~0.65 Gbit/s on c5n.large), which is the
# cap instance-store exists to bypass. gp3 provisioned throughput is independent of
# size (up to 1000 MB/s, 16k IOPS); io2 for higher sustained performance.
###############################################################################

variable "server_data_volume_gb" {
  description = "Size (GB) of the dedicated NFS export data volume. Holds the workload's working set (FILE_SIZE x NUMJOBS per client)."
  type        = number
  default     = 100
}

variable "server_data_volume_type" {
  description = "EBS type for the export volume. gp3 (provisioned throughput/IOPS) by default; io2 for higher sustained performance."
  type        = string
  default     = "gp3"
}

variable "server_data_volume_throughput" {
  description = "Provisioned throughput (MB/s) for the gp3 export volume — set ABOVE the 125 MB/s baseline that bound the export when it lived on the root disk. gp3 supports 125-1000. Ignored for io2."
  type        = number
  default     = 500
}

variable "server_data_volume_iops" {
  description = "Provisioned IOPS for the export volume (gp3: 3000-16000; io2: up to 64000)."
  type        = number
  default     = 4000
}

variable "client_root_volume_gb" {
  description = "Root volume size (GB) for each client. The AL2023 default (~2 GB) is tight once node_exporter + the workload container land; give modest headroom. The volume is encrypted regardless."
  type        = number
  default     = 10
}

###############################################################################
# Network posture — the public/private toggle.
#
# Default (false) keeps the cheap single-public-subnet layout: instances get
# public IPs, SSH is admin_cidr-gated. Fine for throwaway light testing.
#
# private_networking = true is the production-grade posture:
#   - the fleet (clients + server) moves to a PRIVATE subnet with NO public IPs;
#   - a NAT gateway in a public subnet provides egress (package/image pulls);
#   - access + Ansible go through SSM Session Manager (no SSH inbound at all),
#     so the fleet has zero internet-reachable surface.
# The observability box stays in the public subnet as the single, admin_cidr-
# restricted public entry point.
###############################################################################

variable "private_networking" {
  description = "true = fleet in a private subnet (no public IPs) + NAT egress + SSM access (no SSH inbound). false = single public subnet with admin_cidr-gated SSH (cheap default for light testing)."
  type        = bool
  default     = false
}

###############################################################################
# Network placement — cluster placement group for low-latency, low-variance
# networking between the NFS server and clients on the same AZ. Pairs with the
# network-optimized server default above: the two together remove the network
# from the list of accidental confounds in a bandwidth/latency benchmark.
###############################################################################

variable "enable_placement_group" {
  description = "Create a cluster placement group and place the self-managed NFS server in it. Cluster PGs require a single AZ (the harness already pins one) and instance types that support them (network-optimized current-gen; the c5n server default qualifies)."
  type        = bool
  default     = true
}

variable "cluster_clients" {
  description = "Also place the client fleet in the cluster placement group for a co-located, low-variance run. The c5n.large client default supports cluster PGs; off by default only because pinning the whole fleet into one PG in a single AZ can make spot capacity harder to satisfy. Enable for a true co-located low-latency benchmark."
  type        = bool
  default     = false
}

###############################################################################
# Auto-teardown guardrail (Lambda + EventBridge). The serverless cost backstop:
# terminates any TestPlane=true instance older than the age threshold.
###############################################################################

variable "teardown_enabled" {
  description = "Whether to deploy the scheduled auto-teardown guardrail."
  type        = bool
  default     = true
}

variable "max_test_plane_age_hours" {
  description = "Test-plane instances older than this are reaped by the guardrail. Covers a ~2h cycle plus margin."
  type        = number
  default     = 3
}

variable "teardown_schedule" {
  description = "EventBridge schedule expression for the guardrail sweep."
  type        = string
  default     = "rate(1 hour)"
}

variable "manage_guardrail_inline_policy" {
  description = "Whether terraform manages the guardrail role's inline policy. Set false when the deploy principal lacks iam:GetRolePolicy (the policy is then applied out-of-band). See docs/tight-iam-gaps.md."
  type        = bool
  default     = true
}

variable "teardown_dry_run" {
  description = "If true, the guardrail logs what it WOULD terminate but does not. Flip to false to arm it."
  type        = bool
  default     = false
}
