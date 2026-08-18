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
  fi
}
trap cleanup EXIT

# --------------------------------------------------
# Default source directory = current working directory
# User can optionally pass a custom path
# --------------------------------------------------
SOURCE_DIR="${1:-$PWD}"

ARTIFACT_NAME=$(basename "$SOURCE_DIR")
REPOSITORY_URL="https://OpsMx-POC@dev.azure.com/OpsMx-POC/ask/_git/ask"
BRANCH="master"
UPLOAD_URL="https://ec.ssd-sandbox.opsmx.org"
CLI_IMAGE="docker.io/opsmx11/ssd-scanner-cli:v0.6.7"
TOOL="azure"

# Token must be exported before running
SSD_TOKEN="${SSD_TOKEN:-}"

# Auto-generate unique build id and artifact tag
UNIQUE_ID=$(date +%Y%m%d%H%M%S)

echo
echo "============================================================"
echo "        OpsMx Delivery Shield - PoC Scan Runner"
echo "============================================================"
echo

log_info "Source directory : $SOURCE_DIR"
log_info "Artifact name    : $ARTIFACT_NAME"
log_info "Build ID         : $UNIQUE_ID"
log_info "Artifact Tag     : $UNIQUE_ID"

echo
log_info "Performing pre-flight checks..."

# Check source directory
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

# Check Docker installation
if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is not installed or not available in PATH."
  exit 1
fi

# Check Docker daemon
if ! docker info >/dev/null 2>&1; then
  log_error "Docker daemon is not running or current user cannot access Docker."
  log_error "Try: sudo systemctl start docker"
  exit 1
fi

# Check SSD token
if [ -z "$SSD_TOKEN" ]; then
  log_error "SSD_TOKEN is not set."
  echo
  echo "Please export the token before running the scan:"
  echo
  echo "  export SSD_TOKEN='your-token-here'"
  echo "  ./run-ssd-scan.sh"
  echo
  exit 1
fi

# Pull image
log_info "Pulling SSD CLI image: $CLI_IMAGE"

if ! docker pull "$CLI_IMAGE"; then
  log_error "Failed to pull Docker image."
  exit 1
fi

log_success "Pre-flight checks completed successfully."

echo
log_info "Starting SSD scan..."

sudo docker run --rm \
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
    --debug=false \
    --artifact-tag="$UNIQUE_ID" \
    --ssd-token="$SSD_TOKEN"

echo
log_success "SSD scan completed successfully."
log_info "Build ID     : $UNIQUE_ID"
log_info "Artifact Tag : $UNIQUE_ID"
echo
