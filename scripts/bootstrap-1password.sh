#!/bin/bash

# 1Password Connect Bootstrap Script
# This script can be run as a Scalr post-apply hook or manually after Terraform deployment

set -euo pipefail

# Configuration
NAMESPACE="onepassword"
SECRET_NAME="onepassword-connect-token"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required environment variables are set
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if [ -z "${ONEPASSWORD_CONNECT_TOKEN:-}" ]; then
        log_error "ONEPASSWORD_CONNECT_TOKEN environment variable is required"
        log_info "Export your 1Password Connect token: export ONEPASSWORD_CONNECT_TOKEN='your-token-here'"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is required but not installed"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# Wait for Kubernetes to be ready
wait_for_k8s() {
    log_info "Waiting for Kubernetes cluster to be ready..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get nodes &> /dev/null; then
            log_info "Kubernetes cluster is ready"
            return 0
        fi
        
        log_warn "Attempt $attempt/$max_attempts: Waiting for Kubernetes... (sleeping 10s)"
        sleep 10
        ((attempt++))
    done
    
    log_error "Kubernetes cluster is not ready after $max_attempts attempts"
    exit 1
}

# Create the bootstrap secret
create_bootstrap_secret() {
    log_info "Creating 1Password Connect bootstrap secret..."
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Creating namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    else
        log_info "Namespace $NAMESPACE already exists"
    fi
    
    # Create or update the secret
    kubectl create secret generic "$SECRET_NAME" \
        --from-literal=token="$ONEPASSWORD_CONNECT_TOKEN" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Bootstrap secret created successfully"
}

# Verify the secret was created
verify_secret() {
    log_info "Verifying bootstrap secret..."
    
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "✅ Secret $SECRET_NAME exists in namespace $NAMESPACE"
        
        # Check if the secret has the expected key
        if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d | grep -q .; then
            log_info "✅ Secret contains token data"
        else
            log_error "❌ Secret exists but token data is empty"
            exit 1
        fi
    else
        log_error "❌ Secret $SECRET_NAME not found in namespace $NAMESPACE"
        exit 1
    fi
}

# Main execution
main() {
    log_info "Starting 1Password Connect bootstrap process..."
    
    check_prerequisites
    wait_for_k8s
    create_bootstrap_secret
    verify_secret
    
    log_info "🎉 1Password Connect bootstrap completed successfully!"
    log_info "External Secrets Operator can now sync credentials from 1Password."
}

# Run main function
main "$@"
