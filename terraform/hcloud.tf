# Hetzner Cloud resources (SSH key + VPS)

resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "vps" {
  name        = "personal-website-vps-k3s"
  server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "dev"
    type        = "vps"
  }

  # Cloud-init GitOps bootstrap
  # Responsibilities:
  #  - Basic firewall hardening with UFW (allow SSH/HTTP/HTTPS)
  #  - Install k3s server with a FIXED token (var.k3s_token) so future agents / rebuilds can join
  #  - (Optional) Disable Traefik if var.disable_traefik = true (else keep it to serve Argo CD ingress early)
  #  - Seed /var/lib/rancher/k3s/server/manifests with:
  #      * Argo CD HelmChart CR (leveraging k3s embedded helm controller)
  #      * Root Argo CD Application ("app-of-apps") pointing at your repo path k8s/argocd/root
  #  - Set deterministic Argo CD admin password (bcrypt hash provided via var.argocd_admin_password_bcrypt)
  #  - Adjust kubeconfig to use public IP for convenience (NOT for prod automation)
  # NOTE: Any sensitive values in user_data will be stored in Terraform state. Consider secret management later (e.g. External Secrets + SOPS).

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tmpl", {
    k3s_token                     = var.k3s_token
    disable_traefik               = var.disable_traefik
    disable_arg                   = var.disable_traefik ? "--disable traefik" : ""
    argocd_helm_version           = var.argocd_helm_version
    argocd_domain                 = var.argocd_domain
    argocd_admin_password_bcrypt  = var.argocd_admin_password_bcrypt
    git_repo_url                  = var.git_repo_url
    git_root_app_path             = var.git_root_app_path
    git_revision                  = var.git_revision
  })
}
