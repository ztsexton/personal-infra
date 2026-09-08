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
  # Rendered on its own rather than inlined into the cloud-init template, so a
  # provider with no user_data can upload the same script and run it over SSH.
  install_k3s = templatefile("${path.module}/templates/install-k3s.sh.tmpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    # Cannot be local.public_ip: that reads back from hcloud_server.this when the
    # module does not own the address. The script resolves it at runtime instead.
    public_ip         = var.manage_primary_ip ? local.primary_ip.ip_address : ""
    pod_cidr          = var.pod_cidr
    service_cidr      = var.service_cidr
    node_network_cidr = var.node_network_cidr
  })

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

  # Hetzner refuses delete and rebuild API calls while these are set. The
  # provider requires them to move together.
  delete_protection  = var.protect_server
  rebuild_protection = var.protect_server

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
    install_k3s = local.install_k3s
  })
}

# --- Private network ----------------------------------------------------------
#
# Node-to-node traffic (flannel VXLAN, the kubelet API, etcd between servers)
# belongs on a private network rather than the public internet. Created per
# environment: each is its own root module with its own state, so a shared
# network would mean one environment owning a resource the others depend on.
#
# Free on Hetzner, and it is what gives node_network_cidr a value, which is what
# opens the node-to-node firewall rules.
#
# Attaching this to a running server is a hot-attach and does not restart it, but
# k3s only reads --node-ip and --flannel-iface at install time and user_data is
# ignored after creation -- so an existing node keeps using its public IP until
# it is rebuilt. New nodes come up on the private network immediately.
resource "hcloud_network" "this" {
  count = var.node_network_cidr != "" ? 1 : 0

  name     = "${var.server_name}-net"
  ip_range = var.node_network_cidr
  labels   = { environment = var.environment }
}

resource "hcloud_network_subnet" "this" {
  count = var.node_network_cidr != "" ? 1 : 0

  network_id   = hcloud_network.this[0].id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.node_subnet_cidr
}

resource "hcloud_server_network" "this" {
  count = var.node_network_cidr != "" ? 1 : 0

  server_id = hcloud_server.this.id
  subnet_id = hcloud_network_subnet.this[0].id
  # No `ip`: Hetzner assigns from the subnet and cloud-init discovers whichever
  # address it got. A second node then needs no per-node configuration.
}
