output "ipv4_address" {
  value       = module.env.ipv4_address
  description = "Staging public IPv4 (stable across server rebuilds)."
}

output "kubeconfig_command" {
  value       = module.env.kubeconfig_command
  description = "Fetch a working kubeconfig for this cluster."
}

output "ssh_private_key" {
  value       = tls_private_key.this.private_key_openssh
  sensitive   = true
  description = "Private key for this environment. terraform output -raw ssh_private_key > key.pem; chmod 600 key.pem"
}
