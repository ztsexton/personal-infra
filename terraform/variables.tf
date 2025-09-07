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
