# Cloudflare provider configuration
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Cloudflare DNS Records
resource "cloudflare_record" "zachsexton_root" {
  zone_id = var.cloudflare_zone_id_zachsexton
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 1  # Must be 1 when proxied is true
  proxied = true  # Enable Cloudflare proxy
}

resource "cloudflare_record" "petfoodfinder_root" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 1  # Must be 1 when proxied is true
  proxied = true  # Enable Cloudflare proxy
}

resource "cloudflare_record" "vigilo_root" {
  zone_id = var.cloudflare_zone_id_vigilo
  name    = "@"
  content = hcloud_server.vps.ipv4_address
  type    = "A"
  ttl     = 1  # Must be 1 when proxied is true
  proxied = true  # Enable Cloudflare proxy
}

# Cloudflare Zone Settings for zachsexton.com
resource "cloudflare_zone_settings_override" "zachsexton_settings" {
  zone_id = var.cloudflare_zone_id_zachsexton
  
  settings {
    ssl = "strict" # This sets "Full (strict)" SSL mode
    always_use_https = "on"
    min_tls_version = "1.2"
    tls_1_3 = "on"
  }

  # Prevent read-only settings from being modified
  lifecycle {
    ignore_changes = [
      settings.0.proxy_read_timeout,
      settings.0.polish,
      settings.0.response_buffering,
      settings.0.image_resizing,
      settings.0.prefetch_preload,
      # Any other read-only settings that cause issues
    ]
  }
}

# Cloudflare Zone Settings for petfoodfinder.app
resource "cloudflare_zone_settings_override" "petfoodfinder_settings" {
  zone_id = var.cloudflare_zone_id_petfoodfinder
  
  settings {
    ssl = "strict" # This sets "Full (strict)" SSL mode
    always_use_https = "on"
    min_tls_version = "1.2"
    tls_1_3 = "on"
  }

  # Prevent read-only settings from being modified
  lifecycle {
    ignore_changes = [
      settings.0.proxy_read_timeout,
      settings.0.polish,
      settings.0.response_buffering,
      settings.0.image_resizing,
      settings.0.prefetch_preload,
      # Any other read-only settings that cause issues
    ]
  }
}

# Cloudflare Zone Settings for vigilo.dev
resource "cloudflare_zone_settings_override" "vigilo_settings" {
  zone_id = var.cloudflare_zone_id_vigilo
  
  settings {
    ssl = "strict" # This sets "Full (strict)" SSL mode
    always_use_https = "on"
    min_tls_version = "1.2"
    tls_1_3 = "on"
  }

  # Prevent read-only settings from being modified
  lifecycle {
    ignore_changes = [
      settings.0.proxy_read_timeout,
      settings.0.polish,
      settings.0.response_buffering,
      settings.0.image_resizing,
      settings.0.prefetch_preload,
      # Any other read-only settings that cause issues
    ]
  }
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