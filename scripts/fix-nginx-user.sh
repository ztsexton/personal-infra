#!/bin/bash

# Fix nginx user issue script
# Created on: May 18, 2025

set -e
echo "Fixing nginx configuration issue..."

# Check if www-data user exists, create if it doesn't
if ! id -u www-data &>/dev/null; then
    echo "Creating www-data user..."
    useradd -r -M -s /usr/sbin/nologin -c "NGINX web server" www-data
    echo "www-data user created."
fi

# Update nginx.conf to use www-data instead of nginx
echo "Updating nginx.conf..."
sed -i '1s/^user nginx;/user www-data;/' /etc/nginx/nginx.conf

# Test nginx configuration
echo "Testing nginx configuration..."
nginx -t

# Restart nginx if test passes
if [ $? -eq 0 ]; then
    echo "Configuration test passed. Restarting nginx..."
    systemctl restart nginx
    systemctl status nginx
    echo "Nginx has been restarted successfully."
else
    echo "Configuration test failed. Please check logs for more details."
    exit 1
fi