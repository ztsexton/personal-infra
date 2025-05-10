terraform {
  backend "remote" {
    hostname     = "zsexton.scalr.io"             # your account sub‑domain
    organization = "production-personal-websites" # Scalr environment ID or name
    workspaces {
      name = "personal-websites" # Scalr workspace
    }
  }
}