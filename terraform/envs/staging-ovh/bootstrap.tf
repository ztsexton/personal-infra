# Argo CD and the Argo root Application, delivered over SSH exactly as the
# Hetzner path does -- same templates, same script, so the two clusters cannot
# come up configured differently.
#
# Ordered after null_resource.k3s rather than after ovh_vps, because on OVH the
# cluster does not exist until that provisioner has run. On Hetzner cloud-init
# has already done it by the time the server is reachable.

locals {
  bootstrap_onepassword = var.onepassword_connect_token != "" && var.onepassword_credentials_json != ""

  # Everything below is rendered from the shared module's templates by relative
  # path. That is deliberate: a second copy of the Argo CD values or the root
  # Application would drift, and the drift would only show up as one environment
  # syncing something the other does not.
  argocd_values = templatefile("../../modules/environment/templates/argocd-values.yaml.tmpl", {
    argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  })

  root_app = templatefile("../../modules/environment/templates/root-app.yaml.tmpl", {
    git_repo_url      = var.git_repo_url
    git_root_app_path = var.git_root_app_path
    git_revision      = var.git_revision
  })

  bootstrap_script = templatefile("../../modules/environment/templates/bootstrap-cluster.sh.tmpl", {
    argocd_chart_version  = var.argocd_chart_version
    bootstrap_onepassword = local.bootstrap_onepassword
    git_repo_url          = var.git_repo_url
    git_root_app_path     = var.git_root_app_path
    git_revision          = var.git_revision
  })

  do_bootstrap = var.bootstrap_cluster && local.ready
}

resource "null_resource" "cluster_bootstrap" {
  count = local.do_bootstrap ? 1 : 0

  depends_on = [null_resource.k3s]

  triggers = {
    vps            = ovh_vps.this.id
    k3s            = null_resource.k3s[0].id
    script_sha     = sha256(local.bootstrap_script)
    values_sha     = nonsensitive(sha256(local.argocd_values))
    root_app_sha   = sha256(local.root_app)
    op_secrets_sha = nonsensitive(sha256("${var.onepassword_connect_token}:${var.onepassword_credentials_json}"))
  }

  connection {
    type        = "ssh"
    host        = var.vps_host
    user        = var.ssh_user
    private_key = tls_private_key.this.private_key_openssh
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 ${local.remote_dir}/bootstrap"]
  }

  provisioner "file" {
    content     = local.bootstrap_script
    destination = "${local.remote_dir}/bootstrap/bootstrap-cluster.sh"
  }

  provisioner "file" {
    content     = local.argocd_values
    destination = "${local.remote_dir}/bootstrap/argocd-values.yaml"
  }

  provisioner "file" {
    content     = local.root_app
    destination = "${local.remote_dir}/bootstrap/root-app.yaml"
  }

  # Written as files rather than interpolated into the script, so JSON
  # containing quotes cannot break out of the shell quoting.
  provisioner "file" {
    content     = local.bootstrap_onepassword ? var.onepassword_credentials_json : "unused"
    destination = "${local.remote_dir}/bootstrap/1password-credentials.json"
  }

  provisioner "file" {
    content     = local.bootstrap_onepassword ? var.onepassword_connect_token : "unused"
    destination = "${local.remote_dir}/bootstrap/op-connect-token"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 ${local.remote_dir}/bootstrap/*",
      "chmod 0700 ${local.remote_dir}/bootstrap/bootstrap-cluster.sh",
      # remote-exec runs inline commands as a plain /bin/sh script with no
      # `set -e`, so only the last command's status reaches Terraform. The
      # credentials must be shredded either way, so the exit code is captured
      # and re-raised explicitly -- otherwise a failed bootstrap reports as a
      # successful apply.
      <<-EOT
        rc=0
        ${local.sudo}${local.remote_dir}/bootstrap/bootstrap-cluster.sh >>/tmp/cluster-bootstrap.log 2>&1 || rc=$?
        ${local.sudo}cp /tmp/cluster-bootstrap.log /var/log/cluster-bootstrap.log 2>/dev/null || true
        if [ "$rc" -eq 0 ]; then
          tail -n 20 /tmp/cluster-bootstrap.log
        else
          echo "cluster bootstrap failed (exit $rc); last 100 log lines:"
          tail -n 100 /tmp/cluster-bootstrap.log
        fi
        secrets="${local.remote_dir}/bootstrap/op-connect-token ${local.remote_dir}/bootstrap/1password-credentials.json ${local.remote_dir}/bootstrap/op-creds.b64"
        shred -u $secrets 2>/dev/null || rm -f $secrets
        exit $rc
      EOT
    ]
  }
}
