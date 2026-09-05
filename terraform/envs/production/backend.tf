# Production state stays in Scalr, which also executes the run remotely.
# `terraform apply` here streams a Scalr run; that is intentional — production is
# not meant to be applied from a laptop. Use envs/sandbox for local iteration.
terraform {
  backend "remote" {
    hostname     = "zsexton.scalr.io"
    organization = "production-personal-websites"
    workspaces {
      name = "personal-websites"
    }
  }
}
