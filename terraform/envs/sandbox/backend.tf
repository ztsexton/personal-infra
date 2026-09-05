# Local state on purpose. The sandbox exists to be created and destroyed from a
# laptop; it must never share a state file with anything that matters.
terraform {
  backend "local" {
    path = "sandbox.tfstate"
  }
}
