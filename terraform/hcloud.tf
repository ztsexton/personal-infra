# Hetzner Cloud resources (SSH key + VPS)

resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

locals {
  servers = {
    staging = {
      name        = "personal-website-vps-k3s"
      server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
      cloud_init  = "cloud-init.yaml.tmpl"
    }
    production = {
      name        = "personal-prod-vps-k3s"
      server_type = "ccx23" # Dedicated 4 AMD CPU + 16GB RAM + 160 GB SSD + 2 TB Traffic
      cloud_init  = "cloud-init-prod.yaml.tmpl"
    }
  }
}

resource "hcloud_server" "server" {
  for_each = local.servers

  name        = each.value.name
  server_type = each.value.server_type
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = each.key
    type        = "vps"
  }

  user_data = templatefile("${path.module}/templates/${each.value.cloud_init}", {
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
  to   = hcloud_server.server["staging"]
}
