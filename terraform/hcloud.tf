# Hetzner Cloud resources (SSH key + VPS)

resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "vps" {
  name        = "personal-website-vps"
  server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "dev"
    type        = "vps"
  }

  # Cloud-init to install k3s (single node) and basic hardening.
  # - Disables Traefik so we can manage ingress controller explicitly later (optional switch).
  # - Sets up UFW allowing SSH, HTTP, HTTPS.
  # - Installs k3s server with cluster config stored at /etc/rancher/k3s.
  # - Copies kubeconfig to /root/.kube/config with 600 perms.
  user_data = <<-EOF
  #cloud-config
  package_update: true
  package_upgrade: true
  packages:
    - curl
    - apt-transport-https
    - ca-certificates
    - gnupg
    - ufw
  runcmd:
    - echo "[cloud-init] Starting k3s install" | systemd-cat -t cloud-init -p info
    - ufw default deny incoming
    - ufw default allow outgoing
    - ufw allow 22/tcp
    - ufw allow 80/tcp
    - ufw allow 443/tcp
    - echo "y" | ufw enable
    - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
    - mkdir -p /root/.kube
    - cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    - chown root:root /root/.kube/config
    - chmod 600 /root/.kube/config
    - sed -i "s/127.0.0.1/$(curl -s ifconfig.me)/" /root/.kube/config || true
    - echo "[cloud-init] k3s installed" | systemd-cat -t cloud-init -p info
  EOF
}
