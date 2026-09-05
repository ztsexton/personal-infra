# Optional: keep staging state in Scalr instead of locally.
#
#   cd envs/staging
#   terraform init -reconfigure -backend-config=../../backends/staging-scalr.hcl
#
# Requires changing envs/staging/backend.tf from `backend "local"` to
# `backend "remote"`, and creating the workspace in Scalr first. Note that a
# Scalr workspace in remote-execution mode runs plan/apply server-side, which
# defeats local iteration — set the workspace to local execution mode.
hostname     = "zsexton.scalr.io"
organization = "production-personal-websites"

workspaces {
  name = "personal-websites-staging"
}
