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
    }
    production = {
      name        = "personal-prod-vps-k3s"
      server_type = "ccx23" # Dedicated 4 AMD CPU + 16GB RAM + 160 GB SSD + 2 TB Traffic
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

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tmpl", {
    k3s_token = var.k3s_token
  })
}

moved {
  from = hcloud_server.vps
  to   = hcloud_server.server["staging"]
}
