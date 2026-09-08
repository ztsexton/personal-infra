# --- OVH API credentials ------------------------------------------------------
# Written by: ./scripts/setup/ovh-credentials.sh write staging-ovh

variable "ovh_endpoint" {
  description = "OVH API region: ovh-us, ovh-eu or ovh-ca. Credentials are valid against exactly one."
  type        = string
  default     = "ovh-us"
}

variable "ovh_application_key" {
  type      = string
  sensitive = true
}

variable "ovh_application_secret" {
  type      = string
  sensitive = true
}

variable "ovh_consumer_key" {
  description = "Identifies the user and carries the granted scopes. A key that reads /me fine can still be unable to order."
  type        = string
  sensitive   = true
}

variable "ovh_subsidiary" {
  description = "Billing subsidiary. Must match the account: US for an OVHcloud US account."
  type        = string
  default     = "US"
}

# --- The order ----------------------------------------------------------------

variable "vps_plan_code" {
  description = "Catalog plan code. vps-2027-model1 is VPS-1 2027: 2 vCore / 4GB / 40GB NVMe."
  type        = string
  default     = "vps-2027-model1"
}

variable "vps_pricing_mode" {
  description = <<-EOT
    Billing mode, from the public catalog:

      default    $5.35/mo, month to month, cancel any time
      upfront6   $5.08/mo, 6 months paid up front
      upfront12  $4.54/mo, 12 months paid up front

    A commitment can only be exited early by paying out the remainder, so
    `default` is the one that keeps this environment disposable. The $0.81/mo
    difference is not worth locking in a year of an experiment.
  EOT
  type        = string
  default     = "default"
}

variable "vps_duration" {
  description = "Order duration. P1M for month-to-month, P1Y for the upfront12 pricing mode."
  type        = string
  default     = "P1M"
}

variable "vps_datacenter" {
  description = "US-EAST-VA (Vint Hill) or US-WEST-OR (Hillsboro)."
  type        = string
  default     = "US-EAST-VA"
}

variable "vps_os" {
  description = "Image installed at order time. Must be one of the catalog's vps_os values verbatim."
  type        = string
  default     = "Ubuntu 24.04"
}

variable "vps_backup_addon" {
  description = "The automatedBackup addon family is mandatory on this plan. 1-day is $0.50/mo, 7-day is $1.40/mo."
  type        = string
  default     = "option-auto-backup-2027-1-model1"
}

variable "vps_storage_addon" {
  description = "The storage addon family is mandatory. Local storage is included at $0.00."
  type        = string
  default     = "option-storage-local-2027-model1"
}

variable "vps_os_addon" {
  description = "The os addon family is mandatory. Linux is $0.00."
  type        = string
  default     = "option-linux"
}

# --- Installing the SSH key ---------------------------------------------------

variable "vps_image_id" {
  description = <<-EOT
    Image to reinstall with, so the SSH key can be planted.

    Empty on the first apply, which is not optional: the provider requires
    image_id to set public_ssh_key, and image_id is only listed by
    /vps/{serviceName}/images/available -- an endpoint that needs the VPS to
    already exist. There is no data source for it yet (ovh/terraform-provider-ovh
    PR #1268 is still open), so this is genuinely two applies.

    ./scripts/staging-ovh.sh up sequences both and fills this in for you.
  EOT
  type        = string
  default     = ""
}

# --- k3s ----------------------------------------------------------------------

variable "k3s_token" {
  type      = string
  sensitive = true
}

variable "k3s_version" {
  type    = string
  default = "v1.31.5+k3s1"
}

variable "pod_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}

variable "vps_host" {
  description = <<-EOT
    The VPS's public address.

    A variable rather than an attribute because the provider exposes no IP
    anywhere -- not on ovh_vps, not on the ovh_vps data source. It is read from
    /vps/{serviceName}/ips and written back here by ./scripts/staging-ovh.sh,
    on the same pass that discovers vps_image_id.
  EOT
  type        = string
  default     = ""
}

# --- Argo CD bootstrap --------------------------------------------------------

variable "bootstrap_cluster" {
  description = "Install Argo CD and the root Application after k3s. Off until the VPS is known to work."
  type        = bool
  default     = true
}

variable "argocd_admin_password_bcrypt" {
  type      = string
  sensitive = true
  default   = ""
}

variable "argocd_chart_version" {
  type    = string
  default = "7.7.11"
}

variable "git_repo_url" {
  type    = string
  default = "https://github.com/ztsexton/personal-infra.git"
}

variable "git_root_app_path" {
  description = "Argo root app path. Points at the shared staging tree: this environment replaces Hetzner staging rather than running alongside it."
  type        = string
  default     = "k8s/argocd/staging"
}

variable "git_revision" {
  type    = string
  default = "master"
}

variable "onepassword_connect_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "onepassword_credentials_json" {
  type      = string
  sensitive = true
  default   = ""
}

# --- DNS ----------------------------------------------------------------------

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "cloudflare_zone_id_zachsexton" {
  type    = string
  default = ""
}

variable "cloudflare_zone_id_petfoodfinder" {
  type    = string
  default = ""
}

variable "cloudflare_zone_id_vigilo" {
  type    = string
  default = ""
}

variable "manage_dns" {
  description = "Point the staging hostnames at this box. Only ever one environment at a time -- these are the same records Hetzner staging owns."
  type        = bool
  default     = false
}

variable "ssh_user" {
  description = <<-EOT
    The account the SSH key is installed for.

    OVH's Ubuntu image provisions `ubuntu` with passwordless sudo and leaves
    root SSH disabled, so public_ssh_key lands on that account and not root.
    Connecting as root fails with "no supported methods remain", which reads
    like the key was never installed.
  EOT
  type        = string
  default     = "ubuntu"
}
