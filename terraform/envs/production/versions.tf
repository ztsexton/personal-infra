# Pinned exactly, and deliberately NOT to the version production last ran.
#
# hcloud 1.52.0 does not populate `location` (or `datacenter`) when it refreshes
# an existing server: the attribute reads back as "" against a stored "ash", and
# because `location` is ForceNew that alone plans a destroy-and-recreate of the
# production server. 1.68.0 refreshes it correctly and the plan comes back clean.
# Verified by planning both versions with a real refresh against production state.
#
# So the restructure necessarily carries a provider upgrade. Relax to `~>` once
# the migration has been applied.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.68.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 4.52.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.3.1"
    }
  }
}
