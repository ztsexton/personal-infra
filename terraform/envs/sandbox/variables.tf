# --- Credentials --------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit rights on the managed zones."
  type        = string
  sensitive   = true
}

# ssh_private_key is not an input here: this root generates its own keypair.

# --- Cluster ------------------------------------------------------------------

variable "k3s_token" {
  description = "Shared secret token for the k3s cluster."
  type        = string
  sensitive   = true
}

variable "argocd_admin_password_bcrypt" {
  description = "Pre-bcrypted Argo CD admin password: htpasswd -nbBC 10 admin 'pass' | cut -d: -f2"
  type        = string
  sensitive   = true
}

variable "git_revision" {
  description = "Git revision Argo CD tracks."
  type        = string
  default     = "HEAD"
}

# --- 1Password ----------------------------------------------------------------

variable "onepassword_connect_token" {
  description = "1Password Connect token. Empty skips the 1Password bootstrap."
  type        = string
  sensitive   = true
  default     = ""
}

variable "onepassword_credentials_json" {
  description = "Contents of 1password-credentials.json. Empty skips the 1Password bootstrap."
  type        = string
  sensitive   = true
  default     = ""
}

# --- Cloudflare zones ---------------------------------------------------------

variable "cloudflare_zone_id_zachsexton" {
  description = "Cloudflare zone ID for zachsexton.com."
  type        = string
}

variable "cloudflare_zone_id_petfoodfinder" {
  description = "Cloudflare zone ID for petfoodfinder.app."
  type        = string
}

variable "cloudflare_zone_id_vigilo" {
  description = "Cloudflare zone ID for vigilo.dev."
  type        = string
}
