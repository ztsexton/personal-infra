#!/bin/bash

# Cloudflare Settings Import Script
# Created on: May 18, 2025
# This script imports existing Cloudflare zone settings into Terraform state

# Exit on any error
set -e

# Print header
echo "==================================================================="
echo "CLOUDFLARE SETTINGS IMPORT SCRIPT"
echo "==================================================================="
echo "This script will import your existing Cloudflare zone settings into"
echo "Terraform state, allowing Terraform to manage them without changing"
echo "their current values."
echo

# Check if we're in the Terraform directory
if [ ! -f "./cloudflare.tf" ]; then
  echo "Error: This script must be run from the Terraform directory."
  echo "Please run this script from /home/zsext/personal-infra/terraform"
  exit 1
fi

# Domain zone IDs (based on your Terraform variable names)
ZACHSEXTON_ZONE_ID="8da3923e0c792957c16ed8840367bf10"
PETFOODFINDER_ZONE_ID="5c4686d02dc1438e42e79ea476ffeed2"
VIGILO_ZONE_ID="4368f261beffef907a7f9374e09f48b1"

# Backup the current state file
echo "Backing up current Terraform state..."
cp terraform.tfstate terraform.tfstate.import-backup
echo "✅ Created backup at terraform.tfstate.import-backup"
echo

# Import function
import_zone_settings() {
  local zone_id="$1"
  local resource_name="$2"
  local domain_name="$3"
  
  echo "Importing settings for $domain_name (Zone ID: $zone_id)..."
  
  # Run the Terraform import command
  terraform import "cloudflare_zone_settings_override.$resource_name" "$zone_id"
  
  if [ $? -eq 0 ]; then
    echo "✅ Successfully imported $domain_name zone settings into Terraform state"
  else
    echo "❌ Failed to import $domain_name zone settings"
    exit 1
  fi
  echo
}

# Import each domain's zone settings
import_zone_settings "$ZACHSEXTON_ZONE_ID" "zachsexton_settings" "zachsexton.com"
import_zone_settings "$PETFOODFINDER_ZONE_ID" "petfoodfinder_settings" "petfoodfinder.app"
import_zone_settings "$VIGILO_ZONE_ID" "vigilo_settings" "vigilo.dev"

echo "==================================================================="
echo "All zone settings successfully imported into Terraform state!"
echo
echo "Next steps:"
echo "1. Update your cloudflare.tf file with the imported resources"
echo "2. Run 'terraform state show' for each resource to see current values"
echo "3. Run 'terraform plan' to ensure no changes will be made"
echo "==================================================================="