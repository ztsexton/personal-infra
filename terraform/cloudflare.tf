# Cloudflare DNS Records (DNS only, no proxy)

# === zachsexton.com — Production ===

resource "cloudflare_record" "zachsexton_root" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "@"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_record" "zachsexton_argocd" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "argocd"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_petfoodfinder" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "petfoodfinder"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_vigilo" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "vigilo"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_spotifybutler" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "spotifybutler"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_grafana" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "grafana"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_syllabus" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "syllabus"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_zot" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "zot"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

# === zachsexton.com — Staging ===

resource "cloudflare_record" "zachsexton_argocd_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "argocd-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_petfoodfinder_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "petfoodfinder-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_vigilo_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "vigilo-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_spotifybutler_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "spotifybutler-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_grafana_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "grafana-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_syllabus_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "syllabus-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "zachsexton_zot_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "zot-staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

# === petfoodfinder.app — Production ===

resource "cloudflare_record" "petfoodfinder_root" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  name    = "@"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "petfoodfinder_www" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  name    = "www"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

# === petfoodfinder.app — Staging ===

resource "cloudflare_record" "petfoodfinder_staging" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  name    = "staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

# === vigilo.dev — Production ===

resource "cloudflare_record" "vigilo_root" {
  zone_id = var.cloudflare_zone_id_vigilo
  name    = "@"
  content = hcloud_server.production.ipv4_address
  type    = "A"
  ttl     = 3600
  proxied = false
}

# === zachsexton.com — Staging (root) ===

resource "cloudflare_record" "zachsexton_staging" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "staging"
  content = hcloud_server.staging.ipv4_address
  type    = "A"
  ttl     = 300
  proxied = false
}

# DNSSEC settings
resource "cloudflare_zone_dnssec" "zachsexton_dnssec" {
  zone_id = var.cloudflare_zone_id_zachsexton
}

resource "cloudflare_zone_dnssec" "petfoodfinder_dnssec" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
}

resource "cloudflare_zone_dnssec" "vigilo_dnssec" {
  zone_id = var.cloudflare_zone_id_vigilo
}

# Variables for Cloudflare configuration
variable "cloudflare_api_token" {
  sensitive   = true
  type        = string
  description = "Cloudflare API Token"
}

variable "cloudflare_zone_id_zachsexton" {
  type        = string
  description = "Cloudflare Zone ID for zachsexton.com"
}

variable "cloudflare_zone_id_petfoodfinder" {
  type        = string
  description = "Cloudflare Zone ID for petfoodfinder.app"
}

variable "cloudflare_zone_id_vigilo" {
  type        = string
  description = "Cloudflare Zone ID for vigilo.dev"
}
