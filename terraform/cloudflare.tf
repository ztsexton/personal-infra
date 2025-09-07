# Cloudflare DNS Records (DNS only, no proxy)
resource "cloudflare_record" "zachsexton_root" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 3600  # Standard TTL for DNS records
  proxied = false # Disable Cloudflare proxy - DNS only
}

resource "cloudflare_record" "petfoodfinder_root" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 3600  # Standard TTL for DNS records
  proxied = false # Disable Cloudflare proxy - DNS only
}

resource "cloudflare_record" "vigilo_root" {
  zone_id = var.cloudflare_zone_id_vigilo
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 3600  # Standard TTL for DNS records
  proxied = false # Disable Cloudflare proxy - DNS only
}

# DNSSEC settings can still be maintained
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