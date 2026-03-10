# ArgoCD and 1Password are now bootstrapped via cloud-init.
# See templates/cloud-init.yaml.tmpl for the full bootstrap sequence.
# The null_resource provisioners were removed because Scalr's remote
# runners cannot SSH into the servers.
