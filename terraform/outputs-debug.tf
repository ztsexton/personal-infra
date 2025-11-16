# Debug outputs to verify 1Password variables are set

output "onepassword_vars_configured" {
  value = var.onepassword_connect_token != "" && var.onepassword_credentials_json != "" ? "YES" : "NO"
  description = "Whether 1Password variables are configured"
}

output "onepassword_token_length" {
  value = length(var.onepassword_connect_token)
  description = "Length of onepassword_connect_token (0 means not set)"
  sensitive = false
}

output "onepassword_credentials_length" {
  value = length(var.onepassword_credentials_json)
  description = "Length of onepassword_credentials_json (0 means not set)"
  sensitive = false
}
