# Separate resource for 1Password secrets bootstrap
# This can be applied independently without recreating the server

resource "null_resource" "onepassword_secrets" {
  depends_on = [null_resource.install_argocd]

  # Only run if credentials are provided
  count = var.onepassword_connect_token != "" && var.onepassword_credentials_json != "" ? 1 : 0

  provisioner "remote-exec" {
    inline = [
      "kubectl create namespace onepassword || true",
      "kubectl create secret generic onepassword-token --from-literal=token='${var.onepassword_connect_token}' -n onepassword --dry-run=client -o yaml | kubectl apply -f -",
      "echo '${var.onepassword_credentials_json}' | kubectl create secret generic op-credentials --from-file=1password-credentials.json=/dev/stdin -n onepassword --dry-run=client -o yaml | kubectl apply -f -",
      "echo '1Password Connect secrets created successfully'"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }

  # Trigger re-creation when credentials change
  triggers = {
    credentials_hash = md5("${var.onepassword_connect_token}-${var.onepassword_credentials_json}")
  }
}
