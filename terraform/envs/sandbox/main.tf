# Throwaway environment for exercising the full create -> bootstrap -> destroy
# cycle locally. Provisions a server, installs k3s and Argo CD, and points Argo
# at whichever app-of-apps path you give it.
#
# Nothing here is protected: `terraform destroy` removes the server, the primary
# IP and any DNS records.

locals {
  zone_ids = {
    zachsexton    = var.cloudflare_zone_id_zachsexton
    petfoodfinder = var.cloudflare_zone_id_petfoodfinder
    vigilo        = var.cloudflare_zone_id_vigilo
  }
}

# This environment generates and owns its own keypair, so bringing it up needs no
# operator-supplied secret. The private half lives in this root's local state and
# is what Terraform uses to run the cluster bootstrap over SSH.
resource "tls_private_key" "this" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "this" {
  name       = "personal-sandbox-k3s"
  public_key = tls_private_key.this.public_key_openssh
}

module "env" {
  source = "../../modules/environment"

  environment = "sandbox"

  server_name        = var.server_name
  server_type        = var.server_type
  location           = "ash"
  primary_ip_name    = "${var.server_name}-ipv4"
  protect_primary_ip = false
  ssh_key_ids        = [hcloud_ssh_key.this.id]
  ssh_private_key    = tls_private_key.this.private_key_openssh

  k3s_token            = var.k3s_token
  cloudflare_api_token = var.cloudflare_api_token

  bootstrap_cluster            = var.bootstrap_cluster
  argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  git_root_app_path            = var.git_root_app_path
  git_revision                 = var.git_revision

  onepassword_connect_token    = var.onepassword_connect_token
  onepassword_credentials_json = var.onepassword_credentials_json

  cloudflare_zone_ids = local.zone_ids

  # Empty by default: a sandbox should not claim a name that production or
  # staging serves. Add entries here if you need real DNS for a test.
  dns_records = var.dns_records
}

variable "server_name" {
  description = "Hetzner server name. Must not collide with production or staging."
  type        = string
  default     = "personal-sandbox-vps-k3s"
}

variable "server_type" {
  description = "Hetzner server type. cpx21 is the cheapest that comfortably runs the whole stack."
  type        = string
  default     = "cpx21"
}

variable "bootstrap_cluster" {
  description = "Install Argo CD and apply the root Application. Set false to smoke-test only the server and k3s install."
  type        = bool
  default     = true
}

variable "git_root_app_path" {
  description = <<-EOT
    App-of-apps path Argo CD tracks. The staging tree pins staging's LoadBalancer
    IP in its MetalLB pool and Traefik values, so ingress will not come up in a
    sandbox pointed at it — everything upstream of ingress still gets exercised.
    Add a k8s/argocd/sandbox tree if you need working ingress here.
  EOT
  type        = string
  default     = "k8s/argocd/staging"
}

variable "dns_records" {
  description = "Optional A records for this sandbox."
  type = map(object({
    zone = string
    name = string
    ttl  = optional(number, 300)
  }))
  default = {}
}
