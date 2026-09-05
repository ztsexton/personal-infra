# Refactor from the old flat root module into modules/environment. These make the
# restructure a state-only no-op: `terraform plan` after this change must show
# zero resources to add, change or destroy for production.
#
# Delete this file once production has been applied on the new layout.

moved {
  from = hcloud_server.production
  to   = module.env.hcloud_server.this
}

moved {
  from = cloudflare_record.zachsexton_root
  to   = module.env.cloudflare_record.this["zachsexton_root"]
}

moved {
  from = cloudflare_record.zachsexton_argocd
  to   = module.env.cloudflare_record.this["zachsexton_argocd"]
}

moved {
  from = cloudflare_record.zachsexton_petfoodfinder
  to   = module.env.cloudflare_record.this["zachsexton_petfoodfinder"]
}

moved {
  from = cloudflare_record.zachsexton_vigilo
  to   = module.env.cloudflare_record.this["zachsexton_vigilo"]
}

moved {
  from = cloudflare_record.zachsexton_spotifybutler
  to   = module.env.cloudflare_record.this["zachsexton_spotifybutler"]
}

moved {
  from = cloudflare_record.zachsexton_grafana
  to   = module.env.cloudflare_record.this["zachsexton_grafana"]
}

moved {
  from = cloudflare_record.zachsexton_syllabus
  to   = module.env.cloudflare_record.this["zachsexton_syllabus"]
}

moved {
  from = cloudflare_record.zachsexton_zot
  to   = module.env.cloudflare_record.this["zachsexton_zot"]
}

moved {
  from = cloudflare_record.petfoodfinder_root
  to   = module.env.cloudflare_record.this["petfoodfinder_root"]
}

moved {
  from = cloudflare_record.petfoodfinder_www
  to   = module.env.cloudflare_record.this["petfoodfinder_www"]
}

moved {
  from = cloudflare_record.vigilo_root
  to   = module.env.cloudflare_record.this["vigilo_root"]
}

moved {
  from = cloudflare_zone_dnssec.zachsexton_dnssec
  to   = cloudflare_zone_dnssec.zachsexton
}

moved {
  from = cloudflare_zone_dnssec.petfoodfinder_dnssec
  to   = cloudflare_zone_dnssec.petfoodfinder
}

moved {
  from = cloudflare_zone_dnssec.vigilo_dnssec
  to   = cloudflare_zone_dnssec.vigilo
}
