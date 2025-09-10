# k3s and ArgoCD deployment

# Wait for k3s to be ready and get kubeconfig
resource "null_resource" "wait_for_k3s" {
  depends_on = [hcloud_server.vps]

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "until kubectl get nodes; do sleep 5; done",
      "echo 'k3s is ready'"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = var.ssh_private_key
      host        = hcloud_server.vps.ipv4_address
    }
  }
}

# Get kubeconfig from the server
data "external" "kubeconfig" {
  depends_on = [null_resource.wait_for_k3s]
  
  program = ["bash", "-c", <<-EOT
    echo '${var.ssh_private_key}' > /tmp/ssh_key && \
    chmod 600 /tmp/ssh_key && \
    ssh -o StrictHostKeyChecking=no -i /tmp/ssh_key root@${hcloud_server.vps.ipv4_address} \
      'cat /etc/rancher/k3s/k3s.yaml' | \
      sed 's/127.0.0.1/${hcloud_server.vps.ipv4_address}/' | \
      base64 -w 0 | \
      jq -n --arg config "$(cat)" '{"kubeconfig": $config}' && \
    rm -f /tmp/ssh_key
  EOT
  ]
}

# Parse kubeconfig
locals {
  kube_config_raw = base64decode(data.external.kubeconfig.result.kubeconfig)
  kube_config     = yamldecode(local.kube_config_raw)
}

# ArgoCD Helm release
resource "helm_release" "argocd" {
  depends_on = [data.external.kubeconfig]
  
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_helm_version
  namespace  = "argocd"
  create_namespace = true

  values = [
    yamlencode({
      server = {
        insecure = true
        config = {
          "admin.password" = var.argocd_admin_password_bcrypt
        }
      }
      configs = {
        secret = {
          argocdServerAdminPassword = var.argocd_admin_password_bcrypt
        }
      }
    })
  ]

  timeout = 600
}

# ArgoCD root application
resource "kubernetes_manifest" "root_application" {
  depends_on = [helm_release.argocd]
  
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      annotations = {
        "argocd.argoproj.io/sync-wave" = "-2"
      }
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.git_repo_url
        path           = var.git_root_app_path
        targetRevision = var.git_revision
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}
