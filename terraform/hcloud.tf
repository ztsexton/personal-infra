# Hetzner Cloud resources (SSH key + VPS)

resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

# Staging server (shared CPU)
resource "hcloud_server" "staging" {
  name        = "personal-website-vps-k3s"
  server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "staging"
    type        = "vps"
  }

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tmpl", {
    k3s_token = var.k3s_token
  })
}

# Production server (dedicated CPU)
resource "hcloud_server" "production" {
  name        = "personal-prod-vps-k3s"
  server_type = "ccx23" # Dedicated 4 AMD CPU + 16GB RAM + 160 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "production"
    type        = "vps"
  }

  user_data = templatefile("${path.module}/templates/cloud-init-prod.yaml.tmpl", {
    k3s_token                    = var.k3s_token
    argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
    git_repo_url                 = var.git_repo_url
    git_root_app_path            = var.git_root_app_path
    git_revision                 = var.git_revision
    onepassword_connect_token    = var.onepassword_connect_token
    onepassword_credentials_json = var.onepassword_credentials_json
  })
}

moved {
  from = hcloud_server.vps
  to   = hcloud_server.staging
}

moved {
  from = hcloud_server.server["staging"]
  to   = hcloud_server.staging
}

moved {
  from = hcloud_server.server["production"]
  to   = hcloud_server.production
}
