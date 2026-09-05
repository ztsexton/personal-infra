output "ipv4_address" {
  value       = local.public_ip
  description = "Stable public IPv4 for this environment. Safe to hardcode in k8s manifests."
}

output "server_id" {
  value       = hcloud_server.this.id
  description = "Hetzner server ID."
}

output "server_name" {
  value       = hcloud_server.this.name
  description = "Hetzner server name."
}

output "kubeconfig_command" {
  value       = "ssh root@${local.public_ip} cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/${local.public_ip}/' > kubeconfig-${var.environment}.yaml"
  description = "Command to fetch a working kubeconfig (the API cert carries the public IP as a SAN)."
}
