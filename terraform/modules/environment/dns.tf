resource "cloudflare_record" "this" {
  for_each = var.dns_records

  zone_id = var.cloudflare_zone_ids[each.value.zone]
  name    = each.value.name
  content = local.public_ip
  type    = "A"
  ttl     = each.value.ttl
  proxied = false
}
