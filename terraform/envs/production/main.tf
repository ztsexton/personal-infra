locals {
  zone_ids = {
    zachsexton    = var.cloudflare_zone_id_zachsexton
    petfoodfinder = var.cloudflare_zone_id_petfoodfinder
    vigilo        = var.cloudflare_zone_id_vigilo
  }
}

# The Hetzner SSH key is a project-global resource and Hetzner rejects duplicate
# public-key fingerprints, so it is owned here and consumed by the other
# environments through a data source.
resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

variable "ssh_public_key" {
  description = "Public half of the automation SSH key. Note that hcloud_ssh_key.public_key is ForceNew and the API stores a trailing newline, so a whitespace-only difference here replaces the key."
  type        = string
  sensitive   = true
}

module "env" {
  source = "../../modules/environment"

  environment = "production"

  server_name = "personal-prod-vps-k3s"
  server_type = "ccx23" # Dedicated 4 AMD CPU / 16GB / 160GB
  location    = "ash"
  ssh_key_ids = [hcloud_ssh_key.default.id]

  # --- Both of these are deliberately off. ---------------------------------
  #
  # manage_primary_ip: adopting a primary IP rewrites the server's public_net,
  # and the provider powers the server off and on again to reassign the address.
  # Production keeps the IP Hetzner already gave it, so no public_net block is
  # emitted and the plan shows no change to the server. Turning this on is a
  # scheduled-maintenance task, not part of the restructure.
  #
  # bootstrap_cluster: the bootstrap would SSH into the live cluster and run
  # `helm upgrade --install argocd`, replacing the existing kubectl-installed
  # Argo CD. Production's cluster is already running and is not re-bootstrapped
  # by adopting this module.
  #
  # Consequence: production does not yet get the stable IP or the rebuilt
  # bootstrap. Those land when production is next rebuilt, deliberately.
  manage_primary_ip = false
  bootstrap_cluster = false

  ssh_private_key              = var.ssh_private_key
  k3s_token                    = var.k3s_token
  argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  git_root_app_path            = "k8s/argocd/production"
  git_revision                 = var.git_revision

  onepassword_connect_token    = var.onepassword_connect_token
  onepassword_credentials_json = var.onepassword_credentials_json

  cloudflare_zone_ids = local.zone_ids

  dns_records = {
    zachsexton_root          = { zone = "zachsexton", name = "@", ttl = 3600 }
    zachsexton_argocd        = { zone = "zachsexton", name = "argocd" }
    zachsexton_petfoodfinder = { zone = "zachsexton", name = "petfoodfinder" }
    zachsexton_vigilo        = { zone = "zachsexton", name = "vigilo" }
    zachsexton_spotifybutler = { zone = "zachsexton", name = "spotifybutler" }
    zachsexton_grafana       = { zone = "zachsexton", name = "grafana" }
    zachsexton_syllabus      = { zone = "zachsexton", name = "syllabus" }
    zachsexton_zot           = { zone = "zachsexton", name = "zot" }

    petfoodfinder_root = { zone = "petfoodfinder", name = "@" }
    petfoodfinder_www  = { zone = "petfoodfinder", name = "www" }

    vigilo_root = { zone = "vigilo", name = "@", ttl = 3600 }
  }
}

# --- Zone-level settings (not per-environment) --------------------------------

resource "cloudflare_zone_dnssec" "zachsexton" {
  zone_id = var.cloudflare_zone_id_zachsexton
}

resource "cloudflare_zone_dnssec" "petfoodfinder" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
}

resource "cloudflare_zone_dnssec" "vigilo" {
  zone_id = var.cloudflare_zone_id_vigilo
}
