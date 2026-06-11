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
  description = "CIDR block for the single public subnet (sufficient for a throwaway harness)."
  type        = string
  default     = "10.42.1.0/24"
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
  description = "Instance type for client nodes. Keep small during harness dev."
  type        = string
  default     = "t3.small"
}

variable "server_instance_type" {
  description = "Instance type for the self-managed NFS server (when nfs_backend = self_managed). Default is a network-optimized (c5n) type with guaranteed bandwidth: never benchmark on burstable (t3/t2), where the network baseline collapses to a few hundred Mbps once burst credits drain and results become a function of wall-clock time, not your variables."
  type        = string
  default     = "c5n.large"
}

variable "server_root_volume_gb" {
  description = "Root volume size (GB) for the self-managed NFS server. The export (/srv/nfs/share) lives here, so it must hold the workload's working set: fio writes FILE_SIZE x NUMJOBS per client (default 2 GB) across all clients. The AL2023 default root (~8 GB) overflows past a few clients, so default generously."
  type        = number
  default     = 100
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
  description = "Also place the client fleet in the cluster placement group. Off by default because the cheap t3 client default is NOT a supported cluster-PG type — set client_instance_type to a network-optimized type (e.g. c5n.large) before enabling this for a true co-located low-latency run."
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
