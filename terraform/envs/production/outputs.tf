output "ipv4_address" {
  value       = module.env.ipv4_address
  description = "Production public IPv4 (stable across server rebuilds)."
}

output "kubeconfig_command" {
  value       = module.env.kubeconfig_command
  description = "Fetch a working kubeconfig for this cluster."
}
