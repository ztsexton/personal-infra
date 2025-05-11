terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "hcloud_token" {
  sensitive   = true
  type        = string
  description = "Hetzner Cloud API Token"
}

variable "ssh_public_key" {
  sensitive   = true
  type        = string
  description = "Automation ssh public key"
}

provider "hcloud" {
  token = var.hcloud_token
}

# Create SSH key resource
resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

# Create VPS resource
resource "hcloud_server" "vps" {
  name        = "personal-website-vps"
  server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "dev"
    type        = "vps"
  }
}

# Output the VPS's IP address
output "vps_ip" {
  value = hcloud_server.vps.ipv4_address
}