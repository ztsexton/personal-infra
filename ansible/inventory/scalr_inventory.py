#!/usr/bin/env python3
"""
Dynamic inventory that turns Scalr/Terraform JSON outputs into
the structure Ansible expects.

Usage:
    terraform -chdir=infra output -json > /tmp/scalr.json
    ansible-inventory -i inventory/scalr_inventory.py --list
"""
import json, os, sys, subprocess, pathlib, tempfile

# ── 1) Pull or read cached outputs ────────────────────────────────────────────
CACHE = pathlib.Path("/tmp/scalr.json")
if not CACHE.exists():
    # Adjust the path to wherever your Terraform code lives.
    subprocess.run(
        ["terraform", "-chdir=infra", "output", "-json"],
        check=True,
        stdout=CACHE.open("wb"),
    )

with CACHE.open() as f:
    tf_out = json.load(f)

# Expected outputs from Terraform / Scalr module
#   web_public_ip = "203.0.113.10"
#   web_user      = "ubuntu"
#   web_name      = "nginx-web-01"
ip   = tf_out["web_public_ip"]["value"]
user = tf_out["web_user"]["value"]
name = tf_out["web_name"]["value"]

# ── 2) Return Ansible‑style JSON ──────────────────────────────────────────────
inventory = {
    "all": {
        "hosts": [name],
        "vars": {
            "ansible_host": ip,
            "ansible_user": user,
            "ansible_python_interpreter": "/usr/bin/python3",
        },
    },
    "_meta": {"hostvars": {name: {}}},
}
print(json.dumps(inventory, indent=2))
