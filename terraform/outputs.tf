###############################################################################
# Outputs
# nfs_endpoint resolves to whichever backend was built, so downstream layers
# (client fleet mount, Ansible) consume one value regardless of the toggle.
###############################################################################

output "nfs_backend_selected" {
  description = "Which backend was provisioned."
  value       = var.nfs_backend
}

output "nfs_endpoint" {
  description = "Mount endpoint for clients (DNS name for EFS, private IP for self-managed)."
  value = local.use_efs ? (
    length(aws_efs_file_system.this) > 0 ? aws_efs_file_system.this[0].dns_name : null
    ) : (
    length(aws_instance.nfs_server) > 0 ? aws_instance.nfs_server[0].private_ip : null
  )
}

output "nfs_export_path" {
  description = "Path to mount. EFS uses root (/); self-managed exports /srv/nfs/share."
  value       = local.use_efs ? "/" : "/srv/nfs/share"
}

output "vpc_id" {
  value = aws_vpc.harness.id
}

output "subnet_id" {
  value = aws_subnet.harness.id
}

output "client_sg_id" {
  value = aws_security_group.clients.id
}

output "observability_sg_id" {
  value = aws_security_group.observability.id
}

output "server_capacity_type" {
  description = "Capacity type the NFS server was launched with (spot/on_demand)."
  value       = local.use_self_managed ? var.server_capacity_type : "n/a (efs)"
}

###############################################################################
# Fleet addresses — consumed by the Ansible inventory generator (bin/harness)
# and by anyone SSHing in to debug. Public IPs for reach-in (admin_cidr-gated),
# private IPs for intra-VPC traffic.
###############################################################################

output "client_public_ips" {
  description = "Public IPs of the client fleet, in fleet order."
  value       = aws_instance.client[*].public_ip
}

output "client_private_ips" {
  description = "Private IPs of the client fleet, in fleet order."
  value       = aws_instance.client[*].private_ip
}

output "client_capacity_type" {
  description = "Capacity type the client fleet was launched with (spot/on_demand)."
  value       = var.client_capacity_type
}

output "server_public_ip" {
  description = "Public IP of the self-managed NFS server (null for EFS)."
  value       = local.use_self_managed && length(aws_instance.nfs_server) > 0 ? aws_instance.nfs_server[0].public_ip : null
}

output "server_private_ip" {
  description = "Private IP of the self-managed NFS server, a node_exporter scrape target (null for EFS)."
  value       = local.use_self_managed && length(aws_instance.nfs_server) > 0 ? aws_instance.nfs_server[0].private_ip : null
}

output "subnet_az" {
  description = "AZ the harness subnet lives in. The observability EBS volume must match it."
  value       = aws_subnet.harness.availability_zone
}

output "teardown_lambda" {
  description = "Name of the auto-teardown guardrail Lambda (null when disabled)."
  value       = var.teardown_enabled ? aws_lambda_function.teardown[0].function_name : null
}

