# Separate resource for 1Password secrets bootstrap
# This can be applied independently without recreating the server

resource "null_resource" "onepassword_secrets" {
  for_each = (
    var.onepassword_connect_token != "" && var.onepassword_credentials_json != ""
    ? local.servers
    : {}
  )

  depends_on = [null_resource.install_argocd]

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
      host        = hcloud_server.server[each.key].ipv4_address
    }
  }

  # Trigger re-creation when credentials change
  triggers = {
    credentials_hash = md5("${var.onepassword_connect_token}-${var.onepassword_credentials_json}")
  }
}

moved {
  from = null_resource.onepassword_secrets[0]
  to   = null_resource.onepassword_secrets["staging"]
}
