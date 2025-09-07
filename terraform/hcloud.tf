# Hetzner Cloud resources (SSH key + VPS)

resource "hcloud_ssh_key" "default" {
  name       = "personal_hcloud_ssh_key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "vps" {
  name        = "personal-website-vps-k3s"
  server_type = "cpx21" # Shared 3 AMD CPU + 4GB RAM + 80 GB SSD + 2 TB Traffic
  image       = "ubuntu-24.04"
  location    = "ash" # Ashburn, VA location

  ssh_keys = [hcloud_ssh_key.default.id]

  labels = {
    environment = "dev"
    type        = "vps"
  }

  # Cloud-init GitOps bootstrap
  # Responsibilities:
  #  - Basic firewall hardening with UFW (allow SSH/HTTP/HTTPS)
  #  - Install k3s server with a FIXED token (var.k3s_token) so future agents / rebuilds can join
  #  - (Optional) Disable Traefik if var.disable_traefik = true (else keep it to serve Argo CD ingress early)
  #  - Seed /var/lib/rancher/k3s/server/manifests with:
  #      * Argo CD HelmChart CR (leveraging k3s embedded helm controller)
  #      * Root Argo CD Application ("app-of-apps") pointing at your repo path k8s/argocd/root
  #  - Set deterministic Argo CD admin password (bcrypt hash provided via var.argocd_admin_password_bcrypt)
  #  - Adjust kubeconfig to use public IP for convenience (NOT for prod automation)
  # NOTE: Any sensitive values in user_data will be stored in Terraform state. Consider secret management later (e.g. External Secrets + SOPS).
  lifecycle {
    create_before_destroy = true
  }

  user_data = <<-EOF
  #cloud-config
  package_update: true
  package_upgrade: true
  packages:
    - curl
    - ca-certificates
    - ufw
  write_files:
    - path: /root/bootstrap.sh
      permissions: '0755'
      owner: root:root
      content: |
        #!/usr/bin/env bash
        set -euo pipefail
        echo "[bootstrap] Starting" | systemd-cat -t bootstrap -p info
        # Firewall
        ufw default deny incoming || true
        ufw default allow outgoing || true
  for p in 22 80 443; do ufw allow $p/tcp || true; done
        echo 'y' | ufw enable || true

        # Install k3s
        export K3S_TOKEN="${var.k3s_token}"
        DISABLE_ARG="${var.disable_traefik ? "--disable traefik" : ""}"
        INSTALL_K3S_EXEC="server $${DISABLE_ARG} --write-kubeconfig-mode=600"
        echo "[bootstrap] Installing k3s (DISABLE_TRAEFIK=${var.disable_traefik})" | systemd-cat -t bootstrap -p info
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$${INSTALL_K3S_EXEC}" sh -

        # kubeconfig convenience (public IP swap)
        mkdir -p /root/.kube
        cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
        chmod 600 /root/.kube/config
        PUBIP=$(curl -s ifconfig.me || curl -s https://api.ipify.org || echo 127.0.0.1)
        sed -i "s/127.0.0.1/$${PUBIP}/" /root/.kube/config || true

        # Manifests directory
        MANIFEST_DIR=/var/lib/rancher/k3s/server/manifests
        mkdir -p "$${MANIFEST_DIR}"

        # Argo CD HelmChart (k3s helm controller will reconcile)
        cat > "$${MANIFEST_DIR}/argocd.helmchart.yaml" <<'HCH'
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: argo-cd
          namespace: kube-system
        spec:
          repo: https://argoproj.github.io/argo-helm
          chart: argo-cd
          targetNamespace: argocd
          version: ${var.argocd_helm_version}
          valuesContent: |
            server:
              ingress:
                enabled: true
                hosts:
                  - ${var.argocd_domain}
                annotations:
                  cert-manager.io/cluster-issuer: cloudflare-dns
                tls: true
            configs:
              params:
                server.insecure: true
              secret:
                # Pre-bcrypted password (argon/bcrypt accepted). Generate: htpasswd -nbBC 10 "admin" '<plaintext>' | cut -d: -f2
                argocdServerAdminPassword: ${var.argocd_admin_password_bcrypt}
        HCH

        # Root app-of-apps Application (relies on Argo CD CRDs being present shortly after HelmChart sync)
        cat > "$${MANIFEST_DIR}/argocd-root-app.yaml" <<'APP'
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: root
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${var.git_repo_url}
            path: ${var.git_root_app_path}
            targetRevision: ${var.git_revision}
          destination:
            server: https://kubernetes.default.svc
            namespace: argocd
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - CreateNamespace=true
        APP

        echo "[bootstrap] Files seeded. Waiting for k3s to apply..." | systemd-cat -t bootstrap -p info
        # Simple wait loop for Argo CD server pod (best-effort; does not block provisioning forever)
        for i in {1..40}; do
          if kubectl get pods -n argocd 2>/dev/null | grep -q 'argocd-server'; then
            echo "[bootstrap] Argo CD detected" | systemd-cat -t bootstrap -p info
            break
          fi
          sleep 15
        done
        echo "[bootstrap] Complete" | systemd-cat -t bootstrap -p info
  runcmd:
    - /root/bootstrap.sh
  EOF
}
