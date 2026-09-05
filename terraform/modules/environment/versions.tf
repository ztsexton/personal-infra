terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.52"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
