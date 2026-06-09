variable "region" {
  description = "AWS region. Must match the test plane."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile. Match the test plane (default least-privilege; nfs-harness-broad as fallback)."
  type        = string
  default     = "nfs-harness-tight"
}

variable "project_name" {
  description = "Short name used for tagging and resource naming. Match the test plane."
  type        = string
  default     = "nfs-harness"
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair for SSH access to the observability box."
  type        = string
}

variable "observability_instance_type" {
  description = "Instance type for the Prometheus/Grafana box. t3.small is plenty for a PoC."
  type        = string
  default     = "t3.small"
}

# The on-demand toggle. obs-up sets this true; obs-down sets it false and
# applies, which destroys the EC2 instance + attachment but LEAVES the EBS
# volume (and its metrics) standing for the next obs-up to re-attach.
variable "observability_running" {
  description = "Whether the Prometheus/Grafana compute is running. false = compute torn down, metrics volume preserved."
  type        = bool
  default     = true
}

variable "metrics_volume_size_gb" {
  description = "Size of the persistent metrics EBS volume (Prometheus TSDB + Grafana DB)."
  type        = number
  default     = 10
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password. Override in tfvars; do not commit a real one."
  type        = string
  default     = "changeme-harness"
  sensitive   = true
}
