# Partial backend configuration: staging can hold its state either in a Scalr
# workspace or locally.
#
#   Scalr:  terraform init -backend-config=../../backends/staging.hcl
#   Local:  terraform init -backend=false ... or drop a local override; see
#           terraform/README.md.
terraform {
  backend "local" {}
}
