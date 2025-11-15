# k3s and ArgoCD deployment

# Wait for k3s to be ready and install ArgoCD
resource "null_resource" "install_argocd" {
  depends_on = [hcloud_server.vps]

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "until kubectl get nodes; do sleep 5; done",
      "echo 'k3s is ready'"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }

  # Install ArgoCD via kubectl
  provisioner "remote-exec" {
    inline = [
      "kubectl create namespace argocd || true",
      "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml",
      
      # Wait for ArgoCD to be ready
      "kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=600s",
      
      # Configure ArgoCD
      "kubectl patch configmap argocd-cmd-params-cm -n argocd -p '{\"data\":{\"server.insecure\":\"true\"}}'",
      "kubectl -n argocd patch secret argocd-secret -p '{\"stringData\": {\"admin.password\": \"${var.argocd_admin_password_bcrypt}\", \"admin.passwordMtime\": \"'$(date +%FT%T%Z)'\"}}'"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }

  # Apply root application
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      cat <<'ROOTAPP' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: ${var.git_repo_url}
    path: ${var.git_root_app_path}
    targetRevision: ${var.git_revision}
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
ROOTAPP
      EOT
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }

  # Create 1Password bootstrap secrets if credentials are provided
  provisioner "remote-exec" {
    inline = [
      "if [ ! -z '${var.onepassword_connect_token}' ] && [ ! -z '${var.onepassword_credentials_json}' ]; then",
      "  kubectl create namespace onepassword || true",
      "  kubectl create secret generic onepassword-token --from-literal=token='${var.onepassword_connect_token}' -n onepassword --dry-run=client -o yaml | kubectl apply -f -",
      "  echo '${var.onepassword_credentials_json}' | kubectl create secret generic op-credentials --from-file=1password-credentials.json=/dev/stdin -n onepassword --dry-run=client -o yaml | kubectl apply -f -",
      "  echo '1Password Connect secrets created successfully'",
      "else",
      "  echo 'Missing 1Password credentials, skipping bootstrap secret creation'",
      "  echo 'Required: onepassword_connect_token and onepassword_credentials_json'",
      "fi"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }

  # Trigger replacement when server is replaced
  triggers = {
    server_id = hcloud_server.vps.id
  }
}
