#!/usr/bin/env bash
# Prints the resource IDs and ready-to-paste commands needed by the one-time
# migration in terraform/README.md.
#
# Usage:
#   export HCLOUD_TOKEN=...  CLOUDFLARE_API_TOKEN=...
#   export CF_ZONE_ZACHSEXTON=...  CF_ZONE_PETFOODFINDER=...
#
#   ./scripts/archive/tf-migration-ids.sh primary-ips        # Hetzner primary IP IDs
#   ./scripts/archive/tf-migration-ids.sh dns-imports        # cloudflare_record import cmds
#
# The staging state-rm step now lives in ./scripts/archive/tf-split-staging.sh, which
# backs the state up and prompts before touching anything.
set -euo pipefail

HC_API="https://api.hetzner.cloud/v1"
CF_API="https://api.cloudflare.com/client/v4"

die() { echo "error: $*" >&2; exit 1; }

need() {
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is not set"
  done
}

primary_ips() {
  need HCLOUD_TOKEN
  echo "# Hetzner primary IPs"
  curl -sS -H "Authorization: Bearer $HCLOUD_TOKEN" "$HC_API/primary_ips" \
    | jq -r '.primary_ips[] | "id=\(.id)\tip=\(.ip)\tname=\(.name)\tauto_delete=\(.auto_delete)\tassignee=\(.assignee_id // "none")"'
  echo
  echo "# Import with, e.g.:"
  echo "#   terraform import 'module.env.hcloud_primary_ip.protected[0]' <id>"
}

# name -> the dns_records key it maps to in the staging root
staging_records_zachsexton="staging:zachsexton_staging
argocd-staging:zachsexton_argocd_staging
petfoodfinder-staging:zachsexton_petfoodfinder_staging
vigilo-staging:zachsexton_vigilo_staging
spotifybutler-staging:zachsexton_spotifybutler_staging
grafana-staging:zachsexton_grafana_staging
syllabus-staging:zachsexton_syllabus_staging
zot-staging:zachsexton_zot_staging"

cf_record_id() { # $1=zone_id  $2=api_token  $3=record fqdn
  curl -sS -H "Authorization: Bearer $2" \
    "$CF_API/zones/$1/dns_records?name=$3&type=A" \
    | jq -r '.result[0].id // empty'
}

dns_imports() {
  need CLOUDFLARE_API_TOKEN CF_ZONE_ZACHSEXTON CF_ZONE_PETFOODFINDER
  echo "# Run from terraform/envs/staging"
  while IFS=: read -r sub key; do
    [ -n "$sub" ] || continue
    id=$(cf_record_id "$CF_ZONE_ZACHSEXTON" "$CLOUDFLARE_API_TOKEN" "$sub.zachsexton.com")
    if [ -z "$id" ]; then
      echo "# WARNING: no A record found for $sub.zachsexton.com"
      continue
    fi
    echo "terraform import 'module.env.cloudflare_record.this[\"$key\"]' $CF_ZONE_ZACHSEXTON/$id"
  done <<<"$staging_records_zachsexton"

  id=$(cf_record_id "$CF_ZONE_PETFOODFINDER" "$CLOUDFLARE_API_TOKEN" "staging.petfoodfinder.app")
  if [ -n "$id" ]; then
    echo "terraform import 'module.env.cloudflare_record.this[\"petfoodfinder_staging\"]' $CF_ZONE_PETFOODFINDER/$id"
  else
    echo "# WARNING: no A record found for staging.petfoodfinder.app"
  fi
}

staging_state_rm() {
  echo "moved: use ./scripts/archive/tf-split-staging.sh instead (it backs up and prompts)." >&2
  echo "Equivalent commands, for reference:" >&2
  cat <<'EOF'
# Run from terraform/envs/production, BEFORE `terraform apply`.
terraform state rm hcloud_server.staging
terraform state rm cloudflare_record.zachsexton_staging
terraform state rm cloudflare_record.zachsexton_argocd_staging
terraform state rm cloudflare_record.zachsexton_petfoodfinder_staging
terraform state rm cloudflare_record.zachsexton_vigilo_staging
terraform state rm cloudflare_record.zachsexton_spotifybutler_staging
terraform state rm cloudflare_record.zachsexton_grafana_staging
terraform state rm cloudflare_record.zachsexton_syllabus_staging
terraform state rm cloudflare_record.zachsexton_zot_staging
terraform state rm cloudflare_record.petfoodfinder_staging
EOF
}

case "${1:-}" in
  primary-ips)      primary_ips ;;
  dns-imports)      dns_imports ;;
  staging-state-rm) staging_state_rm ;;
  *) die "usage: $0 {primary-ips|dns-imports|staging-state-rm}" ;;
esac
