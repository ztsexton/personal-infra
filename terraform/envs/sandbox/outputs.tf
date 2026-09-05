output "ipv4_address" {
  value       = module.env.ipv4_address
  description = "Sandbox public IPv4. Changes on every rebuild."
}

output "kubeconfig_command" {
  value       = module.env.kubeconfig_command
  description = "Fetch a working kubeconfig for this cluster."
}

output "argocd_port_forward" {
  value       = "kubectl --kubeconfig kubeconfig-sandbox.yaml -n argocd port-forward svc/argocd-server 8080:80"
  description = "Reach the sandbox Argo CD UI without DNS or TLS."
}
