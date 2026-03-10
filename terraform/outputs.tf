output "vps_ip" {
  value       = hcloud_server.server["staging"].ipv4_address
  description = "Staging server IP"
}

output "prod_ip" {
  value       = hcloud_server.server["production"].ipv4_address
  description = "Production server IP"
}
