variable "hcloud_token" {
  sensitive   = true
  type        = string
  description = "Hetzner Cloud API Token"
}

variable "ssh_public_key" {
  sensitive   = true
  type        = string
  description = "Automation ssh public key"
}

# --- k3s bootstrap variables ---

variable "k3s_token" {
  description = "Fixed shared secret token for k3s cluster (used by server + future agents). Generate a strong random string."
  type        = string
  sensitive   = true
}

# --- ArgoCD Terraform deployment variables ---

variable "argocd_helm_version" {
  description = "Argo CD Helm chart version (argo-helm repo)."
  type        = string
  default     = "7.6.9"
}

variable "argocd_admin_password_bcrypt" {
  description = "Pre-bcrypted admin password for deterministic Argo CD bootstrap (htpasswd -nbBC 10 admin 'pass' | cut -d: -f2)."
  type        = string
  sensitive   = true
}

variable "git_repo_url" {
  description = "Git repository URL containing Kubernetes manifests / Applications."
  type        = string
  default     = "https://github.com/ztsexton/personal-infra.git"
}

variable "git_root_app_path" {
  description = "Path within repo for the root (app-of-apps) Argo CD directory."
  type        = string
  default     = "k8s/argocd/root"
}

variable "git_revision" {
  description = "Git revision (branch, tag, or commit) Argo CD should track."
  type        = string
  default     = "HEAD"
}
