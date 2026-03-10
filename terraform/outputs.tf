output "vps_ip" {
  value       = hcloud_server.staging.ipv4_address
  description = "Staging server IP"
}

output "prod_ip" {
  value       = hcloud_server.production.ipv4_address
  description = "Production server IP"
}
