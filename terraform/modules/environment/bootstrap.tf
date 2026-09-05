locals {
  bootstrap_onepassword = var.onepassword_connect_token != "" && var.onepassword_credentials_json != ""

  argocd_values = templatefile("${path.module}/templates/argocd-values.yaml.tmpl", {
    argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  })

  root_app = templatefile("${path.module}/templates/root-app.yaml.tmpl", {
    git_repo_url      = var.git_repo_url
    git_root_app_path = var.git_root_app_path
    git_revision      = var.git_revision
  })

  bootstrap_script = templatefile("${path.module}/templates/bootstrap-cluster.sh.tmpl", {
    argocd_chart_version  = var.argocd_chart_version
    bootstrap_onepassword = local.bootstrap_onepassword
    git_repo_url          = var.git_repo_url
    git_root_app_path     = var.git_root_app_path
    git_revision          = var.git_revision
  })
}

# Argo CD install + Argo root Application, driven from Terraform over SSH.
#
# This is deliberately not the helm/kubernetes providers: those need a kubeconfig
# to configure the provider itself, which is not knowable at plan time on a
# from-scratch apply, so `terraform apply` on an empty state would fail outright.
# Running it here keeps create-from-zero a single command while still failing the
# apply when the cluster does not come up.
resource "null_resource" "cluster_bootstrap" {
  count = var.bootstrap_cluster ? 1 : 0

  triggers = {
    server_id      = hcloud_server.this.id
    script_sha     = sha256(local.bootstrap_script)
    values_sha     = nonsensitive(sha256(local.argocd_values))
    root_app_sha   = sha256(local.root_app)
    op_secrets_sha = nonsensitive(sha256("${var.onepassword_connect_token}:${var.onepassword_credentials_json}"))
  }

  connection {
    type        = "ssh"
    host        = local.public_ip
    user        = "root"
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "install -d -m 0700 /root/bootstrap",
    ]
  }

  provisioner "file" {
    content     = local.bootstrap_script
    destination = "/root/bootstrap/bootstrap-cluster.sh"
  }

  provisioner "file" {
    content     = local.argocd_values
    destination = "/root/bootstrap/argocd-values.yaml"
  }

  provisioner "file" {
    content     = local.root_app
    destination = "/root/bootstrap/root-app.yaml"
  }

  # Written as files rather than interpolated into the script so that JSON
  # containing quotes cannot break out of the shell quoting.
  provisioner "file" {
    content     = local.bootstrap_onepassword ? var.onepassword_credentials_json : "unused"
    destination = "/root/bootstrap/1password-credentials.json"
  }

  provisioner "file" {
    content     = local.bootstrap_onepassword ? var.onepassword_connect_token : "unused"
    destination = "/root/bootstrap/op-connect-token"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 /root/bootstrap/*",
      "chmod 0700 /root/bootstrap/bootstrap-cluster.sh",
      # remote-exec runs inline commands as a plain /bin/sh script with no
      # `set -e`, so only the last command's status reaches Terraform. The
      # credentials have to be shredded either way, so the bootstrap's exit code
      # is captured and re-raised explicitly — otherwise a failed bootstrap would
      # be reported as a successful apply. Redirected rather than piped so the
      # status is the script's own (dash has no `pipefail`).
      <<-EOT
        rc=0
        /root/bootstrap/bootstrap-cluster.sh >>/var/log/cluster-bootstrap.log 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
          tail -n 20 /var/log/cluster-bootstrap.log
        else
          echo "cluster bootstrap failed (exit $rc); last 100 log lines:"
          tail -n 100 /var/log/cluster-bootstrap.log
        fi
        shred -u /root/bootstrap/op-connect-token /root/bootstrap/1password-credentials.json 2>/dev/null \
          || rm -f /root/bootstrap/op-connect-token /root/bootstrap/1password-credentials.json
        exit $rc
      EOT
    ]
  }
}
