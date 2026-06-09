output "observability_running" {
  description = "Whether the observability compute is currently up."
  value       = var.observability_running
}

output "observability_public_ip" {
  description = "Public IP of the Prometheus/Grafana box (null when obs-down)."
  value       = var.observability_running ? aws_instance.prometheus[0].public_ip : null
}

output "grafana_url" {
  description = "Grafana UI. Log in as admin / your grafana_admin_password."
  value       = var.observability_running ? "http://${aws_instance.prometheus[0].public_ip}:3000" : null
}

output "prometheus_url" {
  description = "Prometheus UI (open SG :9090 from admin to reach it)."
  value       = var.observability_running ? "http://${aws_instance.prometheus[0].public_ip}:9090" : null
}

output "scrape_targets" {
  description = "node_exporter targets Prometheus was configured with this apply."
  value       = local.scrape_targets
}

output "metrics_volume_id" {
  description = "Persistent EBS volume holding all metrics. Survives obs-down + test-plane destroy."
  value       = aws_ebs_volume.metrics.id
}
