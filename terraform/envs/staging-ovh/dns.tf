# The staging hostnames, pointed at this box.
#
# These are the SAME records terraform/envs/staging owns. Both roots cannot hold
# them at once -- whichever applies last wins, and the other's state then
# describes records that no longer point where it thinks. Hence manage_dns
# defaulting to false: this environment only takes the records over when it is
# deliberately being made the live staging.
locals {
  zone_ids = {
    zachsexton    = var.cloudflare_zone_id_zachsexton
    petfoodfinder = var.cloudflare_zone_id_petfoodfinder
    vigilo        = var.cloudflare_zone_id_vigilo
  }

  dns_records = {
    zachsexton_staging               = { zone = "zachsexton", name = "staging" }
    zachsexton_argocd_staging        = { zone = "zachsexton", name = "argocd-staging" }
    zachsexton_petfoodfinder_staging = { zone = "zachsexton", name = "petfoodfinder-staging" }
    zachsexton_vigilo_staging        = { zone = "zachsexton", name = "vigilo-staging" }
    zachsexton_spotifybutler_staging = { zone = "zachsexton", name = "spotifybutler-staging" }
    zachsexton_grafana_staging       = { zone = "zachsexton", name = "grafana-staging" }
    zachsexton_syllabus_staging      = { zone = "zachsexton", name = "syllabus-staging" }
    zachsexton_progress_staging      = { zone = "zachsexton", name = "progress-staging" }

    petfoodfinder_staging = { zone = "petfoodfinder", name = "staging" }
  }
}

resource "cloudflare_record" "this" {
  for_each = var.manage_dns && var.vps_host != "" ? local.dns_records : {}

  zone_id = local.zone_ids[each.value.zone]
  name    = each.value.name
  content = var.vps_host
  type    = "A"
  ttl     = 300
  proxied = false
}
