# OVH has three independent API regions and a credential is valid against
# exactly one of them. The wrong endpoint fails as "invalid signature", which
# says nothing about the real problem, so scripts/setup/ovh-credentials.sh
# detects the right one and writes it here.
provider "ovh" {
  endpoint           = var.ovh_endpoint
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}
