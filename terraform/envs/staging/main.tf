locals {
  zone_ids = {
    zachsexton    = var.cloudflare_zone_id_zachsexton
    petfoodfinder = var.cloudflare_zone_id_petfoodfinder
    vigilo        = var.cloudflare_zone_id_vigilo
  }
}

# Owned by envs/production; Hetzner rejects a second key with the same fingerprint.
data "hcloud_ssh_key" "default" {
  name = "personal_hcloud_ssh_key"
}

module "env" {
  source = "../../modules/environment"

  environment = "staging"

  server_name     = "personal-website-vps-k3s"
  server_type     = "cpx21" # Shared 3 AMD CPU / 4GB / 80GB
  location        = "ash"
  primary_ip_name = "personal-staging-ipv4"
  ssh_key_ids     = [data.hcloud_ssh_key.default.id]
  ssh_private_key = var.ssh_private_key

  k3s_token = var.k3s_token

  argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  git_root_app_path            = "k8s/argocd/staging"
  git_revision                 = var.git_revision

  onepassword_connect_token    = var.onepassword_connect_token
  onepassword_credentials_json = var.onepassword_credentials_json

  cloudflare_zone_ids = local.zone_ids

  dns_records = {
    zachsexton_staging               = { zone = "zachsexton", name = "staging" }
    zachsexton_argocd_staging        = { zone = "zachsexton", name = "argocd-staging" }
    zachsexton_petfoodfinder_staging = { zone = "zachsexton", name = "petfoodfinder-staging" }
    zachsexton_vigilo_staging        = { zone = "zachsexton", name = "vigilo-staging" }
    zachsexton_spotifybutler_staging = { zone = "zachsexton", name = "spotifybutler-staging" }
    zachsexton_grafana_staging       = { zone = "zachsexton", name = "grafana-staging" }
    zachsexton_syllabus_staging      = { zone = "zachsexton", name = "syllabus-staging" }
    zachsexton_zot_staging           = { zone = "zachsexton", name = "zot-staging" }

    petfoodfinder_staging = { zone = "petfoodfinder", name = "staging" }
  }
}
