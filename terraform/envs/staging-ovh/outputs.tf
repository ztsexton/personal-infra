output "service_name" {
  description = "OVH's internal name for the VPS, e.g. vps-abc12345.vps.ovh.us. Needed to look up available images."
  value       = ovh_vps.this.service_name
}

# The provider exposes no address, so this is only as current as the last
# `staging-ovh.sh up`. Re-read it from the API with `staging-ovh.sh status`.
output "ipv4_address" {
  value = var.vps_host
}

output "ssh_private_key" {
  value     = tls_private_key.this.private_key_openssh
  sensitive = true
}

output "monthly_cost_note" {
  description = "What this environment bills, so it is visible without opening the OVH manager."
  value = format(
    "%s at %s + backups = the catalog price for pricing_mode=%s. Terminating stops billing at the end of the current term.",
    var.vps_plan_code, var.vps_datacenter, var.vps_pricing_mode
  )
}
