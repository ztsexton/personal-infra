# Providers are pinned to the exact versions production already runs, so the
# restructure lands as a pure refactor with no provider upgrade mixed into it.
# Relax these to `~>` constraints once the migration has been applied.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.52.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 4.52.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.2.4"
    }
  }
}
