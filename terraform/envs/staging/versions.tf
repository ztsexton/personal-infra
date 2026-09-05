# Exact versions live in .terraform.lock.hcl, which is committed and is what
# actually governs a run. These constraints only set the floor.
#
# Do not drop hcloud below 1.68: 1.52.0 does not populate `location` when it
# refreshes an existing server, and since `location` is ForceNew that alone plans
# a destroy-and-recreate of the production server.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
}
