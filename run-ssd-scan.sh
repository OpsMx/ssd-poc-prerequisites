#!/bin/bash

set -euo pipefail

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log_error "Scan execution failed. Exit code: $exit_code"
    log_error "Please review the messages above and share the complete output with the OpsMx team if needed."
  fi
}
trap cleanup EXIT

SOURCE_DIR="${1:-/root/SunSystems}"

ARTIFACT_NAME="SunSystems"
REPOSITORY_URL="https://OpsMx-POC@dev.azure.com/OpsMx-POC/ask/_git/ask"
BRANCH="main"
UPLOAD_URL="https://customer-poc-demo.ssd-sandbox.opsmx.org"
CLI_IMAGE="docker.io/opsmx11/ssd-scanner-cli:v0.6.7"
TOOL="azure"

SSD_TOKEN="${SSD_TOKEN:-REPLACE_WITH_SSD_TOKEN}"

UNIQUE_ID=$(date +%Y%m%d%H%M%S)

echo
echo "============================================================"
echo "        OpsMx Delivery Shield - PoC Scan Runner"
echo "============================================================"
echo

log_info "Source directory : $SOURCE_DIR"
log_info "Build ID         : $UNIQUE_ID"
log_info "Artifact Tag     : $UNIQUE_ID"

echo
log_info "Performing pre-flight checks..."

if [ "$(id -u)" -eq 0 ]; then
  log_warn "Running as root user."
else
  if sudo -n true 2>/dev/null; then
    log_info "Sudo access: available"
  else
    log_error "Current user does not have passwordless sudo access."
    log_error "Please run with a user having sudo privileges or configure passwordless sudo."
    exit 1
  fi
fi

if [ ! -d "$SOURCE_DIR" ]; then
  log_error "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

if [ ! -r "$SOURCE_DIR" ]; then
  log_error "Source directory is not readable: $SOURCE_DIR"
  exit 1
fi

if [ -z "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]; then
  log_error "Source directory is empty: $SOURCE_DIR"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is not installed or not available in PATH."
  log_error "Install Docker and try again."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log_error "Docker daemon is not running or current user cannot access Docker."
  log_error "Start Docker service and ensure the user is part of the docker group."
  exit 1
fi

if [[ "$SSD_TOKEN" == "REPLACE_WITH_SSD_TOKEN" || -z "$SSD_TOKEN" ]]; then
  log_error "SSD token is not configured."
  log_error "Edit this script and replace REPLACE_WITH_SSD_TOKEN with the actual token,"
  log_error "or export SSD_TOKEN before running the script."
  exit 1
fi

if ! curl -fsSL --connect-timeout 10 "$UPLOAD_URL/health" >/dev/null 2>&1; then
  log_warn "Unable to verify connectivity to SSD upload URL."
  log_warn "The scan may still work if the endpoint is reachable during upload."
fi

log_info "Pulling SSD CLI image: $CLI_IMAGE"

if ! docker pull "$CLI_IMAGE"; then
  log_error "Failed to pull Docker image: $CLI_IMAGE"
  log_error "Check internet connectivity and Docker registry access."
  exit 1
fi

log_success "Pre-flight checks completed successfully."

echo
log_info "Starting SSD scan..."

if docker run --rm \
  -v "$SOURCE_DIR:/home/scanner/source:rw" \
  "$CLI_IMAGE" \
    --scanners=cdxgen \
    --cdxgen-scanners=sourcecodesbom \
    --source-code-path=/home/scanner/source \
    --repository-url="$REPOSITORY_URL" \
    --branch="$BRANCH" \
    --build-id="$UNIQUE_ID" \
    --upload-url="$UPLOAD_URL" \
    --offline-mode=false \
    --artifact-type=file \
    --artifact-name="$ARTIFACT_NAME" \
    --artifact-path=/home/scanner/source \
    --keep-results=true \
    --tool="$TOOL" \
    --debug=false \
    --artifact-tag="$UNIQUE_ID" \
    --ssd-token="$SSD_TOKEN"; then

  echo
  log_success "SSD scan completed successfully."
  log_info "Build ID     : $UNIQUE_ID"
  log_info "Artifact Tag : $UNIQUE_ID"
  echo

else
  log_error "Docker scan command failed."
  exit 1
fi
