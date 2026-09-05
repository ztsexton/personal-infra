# --- Identity -----------------------------------------------------------------

variable "environment" {
  description = "Environment name (production, staging, sandbox). Used for labels and default resource names."
  type        = string
}

# --- Server -------------------------------------------------------------------

variable "server_name" {
  description = "Hetzner server name."
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g. ccx23 dedicated, cpx21 shared)."
  type        = string
}

variable "server_image" {
  description = "Hetzner base image."
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Hetzner location (ash = Ashburn, VA)."
  type        = string
  default     = "ash"
}

variable "ssh_key_ids" {
  description = "IDs of existing hcloud_ssh_key resources to install on the server."
  type        = list(string)
}

variable "ssh_private_key" {
  description = "Private key matching var.ssh_key_ids, used by Terraform to run the cluster bootstrap over SSH."
  type        = string
  sensitive   = true
}

variable "primary_ip_name" {
  description = "Name of the hcloud_primary_ip. The address outlives server destroy/recreate, which is what keeps the MetalLB pool and Traefik loadBalancerIP in the k8s manifests valid. Unused when manage_primary_ip is false."
  type        = string
  default     = ""
}

# --- k3s ----------------------------------------------------------------------

variable "k3s_token" {
  description = "Shared secret token for the k3s cluster."
  type        = string
  sensitive   = true
}

variable "k3s_version" {
  description = "Pinned k3s version (INSTALL_K3S_VERSION). Empty string installs the current stable channel."
  type        = string
  default     = "v1.31.5+k3s1"
}

variable "pod_cidr" {
  description = "k3s pod CIDR, allowed through ufw."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "k3s service CIDR, allowed through ufw."
  type        = string
  default     = "10.43.0.0/16"
}

# --- Cluster bootstrap --------------------------------------------------------

variable "bootstrap_cluster" {
  description = "Install Argo CD and apply the app-of-apps root Application after the server comes up."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version (argo-helm repo)."
  type        = string
  default     = "7.6.9"
}

variable "argocd_admin_password_bcrypt" {
  description = "Pre-bcrypted Argo CD admin password: htpasswd -nbBC 10 admin 'pass' | cut -d: -f2"
  type        = string
  sensitive   = true
}

variable "git_repo_url" {
  description = "Git repository containing the Argo CD Applications."
  type        = string
  default     = "https://github.com/ztsexton/personal-infra.git"
}

variable "git_root_app_path" {
  description = "Path within the repo to the root (app-of-apps) directory."
  type        = string
}

variable "git_revision" {
  description = "Git revision Argo CD tracks."
  type        = string
  default     = "HEAD"
}

# --- 1Password ----------------------------------------------------------------

variable "onepassword_connect_token" {
  description = "1Password Connect token. Empty skips the 1Password secret bootstrap."
  type        = string
  sensitive   = true
  default     = ""
}

variable "onepassword_credentials_json" {
  description = "Contents of 1password-credentials.json. Empty skips the 1Password secret bootstrap."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare token with DNS edit rights. Written straight into the cert-manager cloudflare-api-token secret so an environment can issue certificates without waiting on the 1Password bootstrap. Empty skips it, and no TLS certificate will be issued."
  type        = string
  sensitive   = true
  default     = ""
}

variable "registry_dockerconfigjson" {
  description = "Docker config JSON for the private registry, e.g. {\"auths\":{\"host\":{\"auth\":\"<base64 user:pass>\"}}}. Becomes the zot-registry-credentials pull secret. Cannot be derived from zot-auth, which holds an htpasswd line rather than a password. Empty skips it and private images will not pull."
  type        = string
  sensitive   = true
  default     = ""
}

# --- DNS ----------------------------------------------------------------------

variable "cloudflare_zone_ids" {
  description = "Map of zone alias => Cloudflare zone ID, e.g. { zachsexton = \"abc...\" }."
  type        = map(string)
  default     = {}
}

variable "dns_records" {
  description = <<-EOT
    A records pointing at this environment's primary IP, keyed by a stable identifier.
    `zone` must be a key of var.cloudflare_zone_ids. `name` is the record name ("@" for apex).
  EOT
  type = map(object({
    zone = string
    name = string
    ttl  = optional(number, 300)
  }))
  default = {}
}

variable "protect_primary_ip" {
  description = "Guard the primary IP with prevent_destroy. True for production and staging, where losing the address means rewriting the MetalLB pool and Traefik loadBalancerIP in git. False for throwaway environments that need `terraform destroy` to complete."
  type        = bool
  default     = true
}

variable "enable_ipv6" {
  description = "Keep the server's public IPv6. Hetzner enables it by default, so leaving this true is what makes adopting an existing server a zero-diff change — flipping it rewrites public_net, which power-cycles the server."
  type        = bool
  default     = true
}

variable "manage_primary_ip" {
  description = "Let this module own a dedicated hcloud_primary_ip and pin the server to it. Set false when adopting an already-running server: no public_net block is emitted, so the plan shows no change to it. The provider powers a server off and on again to reassign its IP, so flipping this to true on a live environment is an outage — schedule it."
  type        = bool
  default     = true
}

# manage_primary_ip = true requires a name to give the address.
locals {
  _validate_primary_ip_name = var.manage_primary_ip && var.primary_ip_name == "" ? tobool("primary_ip_name must be set when manage_primary_ip is true") : true
}
