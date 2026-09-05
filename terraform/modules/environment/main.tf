# The primary IP is created independently of the server and never auto-deleted,
# so the address survives destroying and recreating the server. That is what lets
# the MetalLB address pool and the Traefik loadBalancerIP in the k8s manifests
# stay valid across a full rebuild.
#
# Two blocks because `prevent_destroy` only accepts a literal. Long-lived
# environments protect the address; throwaway ones need `terraform destroy` to
# actually complete.
resource "hcloud_primary_ip" "protected" {
  count = var.manage_primary_ip && var.protect_primary_ip ? 1 : 0

  name        = var.primary_ip_name
  type        = "ipv4"
  location    = var.location
  auto_delete = false
  labels      = { environment = var.environment }

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_primary_ip" "ephemeral" {
  count = var.manage_primary_ip && !var.protect_primary_ip ? 1 : 0

  name        = var.primary_ip_name
  type        = "ipv4"
  location    = var.location
  auto_delete = false
  labels      = { environment = var.environment }
}

locals {
  primary_ip = one(concat(hcloud_primary_ip.protected, hcloud_primary_ip.ephemeral))

  # With manage_primary_ip = false the server keeps whatever address Hetzner gave
  # it and no public_net block is emitted at all, so adopting this module against
  # an already-running server produces no diff on it.
  public_ip = var.manage_primary_ip ? local.primary_ip.ip_address : hcloud_server.this.ipv4_address
}

resource "hcloud_server" "this" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.server_image
  location    = var.location
  ssh_keys    = var.ssh_key_ids

  # Emitted only when this module owns the address. Rewriting public_net on an
  # existing server is an in-place update, but the provider powers the server off
  # before reassigning the IP and back on afterwards — a real outage. Adopting a
  # running server therefore leaves the block absent entirely.
  dynamic "public_net" {
    for_each = var.manage_primary_ip ? [1] : []
    content {
      ipv4_enabled = true
      ipv4         = local.primary_ip.id
      ipv6_enabled = var.enable_ipv6
    }
  }

  labels = {
    environment = var.environment
    type        = "vps"
  }

  # Both of these are ForceNew on hcloud_server, and both would otherwise destroy
  # and recreate a perfectly healthy server:
  #
  #   user_data -- only ever read at first boot, but stored as a hash and diffed
  #     forever after. Adopting a running server into this module renders a
  #     different template than the one it booted with, which alone is enough to
  #     trigger a rebuild.
  #   ssh_keys  -- rotating the Hetzner key replaces hcloud_ssh_key, which turns
  #     this into "known after apply" and takes the server with it.
  #
  # Neither has any effect on a running machine, so neither should ever drive a
  # replacement. Rebuild deliberately instead:
  #   terraform apply -replace=module.env.hcloud_server.this
  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  # k3s only. Nothing beyond the cluster token goes into user_data; Argo CD and
  # the 1Password credentials arrive over SSH from bootstrap.tf, because user_data
  # stays readable through the Hetzner console and API for the life of the server.
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tmpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    # Cannot be local.public_ip: that reads back from this very resource when the
    # module does not own the address. cloud-init resolves it at runtime instead.
    public_ip    = var.manage_primary_ip ? local.primary_ip.ip_address : ""
    pod_cidr     = var.pod_cidr
    service_cidr = var.service_cidr
  })
}
