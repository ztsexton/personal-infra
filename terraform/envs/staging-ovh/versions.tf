terraform {
  required_version = ">= 1.5.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.19"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Pinned to the same major as the other roots. v5 renamed
      # cloudflare_record to cloudflare_dns_record and would silently plan a
      # destroy-and-recreate of every record.
      version = "~> 4.0"
    }
  }
}
