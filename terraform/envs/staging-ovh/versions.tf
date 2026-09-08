terraform {
  required_version = ">= 1.5.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.19"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
