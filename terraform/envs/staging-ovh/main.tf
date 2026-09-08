# A VPS-1 at OVH running the same k3s as staging, to find out whether OVH can
# host this stack before anything depends on it.
#
# Deliberately NOT wired to DNS or Argo CD. The staging manifests hardcode the
# Hetzner address in the MetalLB pool and Traefik's loadBalancerIP, so a second
# cluster syncing the same git path would sit there with a permanently pending
# LoadBalancer. This environment proves the box orders, boots, takes our key and
# runs k3s. Routing comes after that answer is yes.
#
# What is different from Hetzner, and why this is a separate root rather than a
# variant of modules/environment:
#
#   no user_data      ovh_vps has no cloud-init field at all, so the k3s install
#                     is uploaded and run over SSH instead of at first boot.
#                     Same script either way -- see templates/install-k3s.sh.tmpl
#                     in the shared module.
#   no primary IP     the address belongs to the VPS and cannot be detached, so
#                     there is no equivalent of the Hetzner spin-down trick that
#                     keeps an address alive while the server is gone. The
#                     provider does not expose the address at all -- not on the
#                     resource, not as a data source -- so it is read from
#                     /vps/{serviceName}/ips by staging-ovh.sh and passed back in
#                     as vps_host.
#   a subscription    ovh_vps is an order. Destroying it terminates the service,
#                     but on a committed pricing mode termination takes effect at
#                     the end of the term rather than immediately.

resource "tls_private_key" "this" {
  algorithm = "ED25519"
}

resource "ovh_vps" "this" {
  display_name   = "staging-ovh-k3s"
  ovh_subsidiary = var.ovh_subsidiary

  plan = [{
    plan_code    = var.vps_plan_code
    duration     = var.vps_duration
    pricing_mode = var.vps_pricing_mode
    quantity     = 1

    configuration = [
      { label = "vps_datacenter", value = var.vps_datacenter },
      { label = "vps_os", value = var.vps_os },
    ]
  }]

  # Every one of these families is marked mandatory in the catalog for this
  # plan; omitting any of them fails the order rather than defaulting.
  plan_option = [
    {
      plan_code    = var.vps_os_addon
      duration     = var.vps_duration
      pricing_mode = var.vps_pricing_mode
      quantity     = 1
    },
    {
      plan_code    = var.vps_storage_addon
      duration     = var.vps_duration
      pricing_mode = var.vps_pricing_mode
      quantity     = 1
    },
    {
      plan_code    = var.vps_backup_addon
      duration     = var.vps_duration
      pricing_mode = var.vps_pricing_mode
      quantity     = 1
    },
  ]

  # Install options. All three are sent together to /vps/{name}/rebuild, and the
  # provider rejects public_ssh_key unless image_id is set alongside it -- hence
  # the empty first pass. do_not_send_password is what stops OVH mailing a root
  # password, which is otherwise how you are expected to get in.
  image_id       = var.vps_image_id != "" ? var.vps_image_id : null
  public_ssh_key = var.vps_image_id != "" ? trimspace(tls_private_key.this.public_key_openssh) : null

  # do_not_send_password is deliberately ABSENT.
  #
  # The provider cannot handle it either way. /vps/{name} has no field for it,
  # so nothing is ever read back:
  #
  #   unset  -> "still indicated an unknown value for do_not_send_password"
  #             (invalid result object, fails the apply AFTER the order lands)
  #   = true -> "was cty.True, but now null" (inconsistent result after apply)
  #
  # Leaving it out and ignoring it is the only combination that applies cleanly.
  # The consequence is that OVH emails a root password on every reinstall, so
  # the k3s install disables SSH password authentication -- see
  # install-k3s.sh.tmpl. That is worth doing regardless.

  lifecycle {
    # Ordering charges the account's default payment method. Terraform replacing
    # this for a changed attribute would silently buy a second one.
    prevent_destroy = false

    ignore_changes = [
      # Order-time only. Once the service exists these describe how it was
      # bought, not what it is, and the catalog reprices them independently.
      plan,
      plan_option,
      # Never readable, so every plan would show a phantom change.
      do_not_send_password,
    ]
  }
}

locals {
  # Everything the provisioners run needs root, and the account we can reach is
  # not root. Empty when it is, so this stays correct if the image ever changes.
  sudo       = var.ssh_user == "root" ? "" : "sudo "
  remote_dir = var.ssh_user == "root" ? "/root" : "/home/${var.ssh_user}"

  # Both are discovered from the API after the order lands, so neither exists on
  # the first apply. The k3s step waits for both.
  ready = var.vps_image_id != "" && var.vps_host != ""

  install_k3s = templatefile("../../modules/environment/templates/install-k3s.sh.tmpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    # Empty is fine and is what happens before vps_host is known: the script
    # falls back to resolving its own address at runtime.
    public_ip = var.vps_host
    pod_cidr  = var.pod_cidr

    service_cidr = var.service_cidr
    # Single node with no private network: the node-to-node block stays out.
    node_network_cidr = ""
  })
}

# The Hetzner path gets this for free through cloud-init. Here it is an explicit
# upload-and-run, which is why it is a null_resource rather than an attribute.
resource "null_resource" "k3s" {
  count = local.ready ? 1 : 0

  triggers = {
    vps    = ovh_vps.this.id
    script = sha256(local.install_k3s)
  }

  connection {
    type        = "ssh"
    host        = var.vps_host
    user        = var.ssh_user
    private_key = tls_private_key.this.private_key_openssh
    timeout     = "10m"
  }

  # Uploaded to the connecting user's home directory: as a non-root user there
  # is nowhere else writable, and the script does not care where it runs from.
  provisioner "file" {
    content     = local.install_k3s
    destination = "${local.remote_dir}/install-k3s.sh"
  }

  # remote-exec does not run under `set -e`, so a failure partway through still
  # reports success unless the exit code is captured deliberately.
  provisioner "remote-exec" {
    inline = [
      "chmod 0700 ${local.remote_dir}/install-k3s.sh",
      "${local.sudo}bash -c '${local.remote_dir}/install-k3s.sh 2>&1 | tee -a /var/log/k3s-bootstrap.log; exit $${PIPESTATUS[0]}'",
    ]
  }
}
