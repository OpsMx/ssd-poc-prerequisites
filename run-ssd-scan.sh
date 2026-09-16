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
CLI_IMAGE="docker.io/opsmx11/ssd-scanner-cli:v0.6.9"
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

docker run --rm \
  -v "$SOURCE_DIR:/home/scanner/source:rw" \
  -v "$PWD/ssd-results:/home/scanner/.local/bin/ssd-scan-results:rw" \
  "$CLI_IMAGE" \
    --scanners=cdxgen \
    --cdxgen-scanners=sourcecodesbom \
    --source-code-path=/home/scanner/source \
    --repository-url="$REPOSITORY_URL" \
    --branch="$BRANCH" \
    --build-id="$UNIQUE_ID" \
    --upload-url="$UPLOAD_URL" \
    --offline-mode=true \
    --artifact-type=file \
    --artifact-name="$ARTIFACT_NAME" \
    --artifact-path=/home/scanner/source \
    --keep-results=true \
    --debug=false \
    --artifact-tag="$UNIQUE_ID"

echo
log_success "SSD scan completed successfully."
log_info "Build ID     : $UNIQUE_ID"
log_info "Artifact Tag : $UNIQUE_ID"
echo

# --------------------------------------------------
# SBOM normalization and upload
# --------------------------------------------------

echo
log_info "SSD scan completed. Enter the local SBOM directory path."
read -r -p "SBOM directory path: " SBOM_PATH

if [ -z "$SBOM_PATH" ]; then
  log_error "SBOM path cannot be empty."
  exit 1
fi

# User enters the SBOM DIRECTORY, not the JSON filename.
# Example:
#   /home/opsmx/dotnet/ssd-results/scan-20260911-080731/cdxgen
#
# The script finds the generated cdxgen JSON inside that directory.
if [ ! -d "$SBOM_PATH" ]; then
  log_error "SBOM directory does not exist: $SBOM_PATH"
  exit 1
fi

SBOM_DIR="$(cd "$SBOM_PATH" && pwd)"

# Prefer the normal cdxgen filename pattern.
SBOM_FILE=""
while IFS= read -r candidate; do
  SBOM_FILE="$candidate"
  break
done < <(find "$SBOM_DIR" -maxdepth 1 -type f \
  \( -name 'sha256-*-cdxgen.json' -o -name 'sha256_*-cdxgen.json' \) \
  -print | sort)

# Fall back to any JSON file if the expected cdxgen pattern is not found.
if [ -z "$SBOM_FILE" ]; then
  while IFS= read -r candidate; do
    SBOM_FILE="$candidate"
    break
  done < <(find "$SBOM_DIR" -maxdepth 1 -type f -name '*.json' \
    ! -name 'sbom.json' -print | sort)
fi

if [ -z "$SBOM_FILE" ]; then
  log_error "No SBOM JSON file found in directory: $SBOM_DIR"
  exit 1
fi

SBOM_FILENAME="$(basename "$SBOM_FILE")"
log_info "SBOM discovered: $SBOM_FILE"

# Accept both sha256-<sha>-<tool>.json and sha256_<sha>-<tool>.json.
# ARTIFACT_SHA contains only the hexadecimal SHA, without the sha256 prefix.
if [[ "$SBOM_FILENAME" =~ ^sha256-([^-]+)-([^.]+)\.json$ ]]; then
  ARTIFACT_SHA="${BASH_REMATCH[1]}"
  SBOM_TOOL="${BASH_REMATCH[2]}"
elif [[ "$SBOM_FILENAME" =~ ^sha256_([^-]+)-([^.]+)\.json$ ]]; then
  ARTIFACT_SHA="${BASH_REMATCH[1]}"
  SBOM_TOOL="${BASH_REMATCH[2]}"
else
  log_error "Invalid SBOM filename: $SBOM_FILENAME"
  log_error "Expected: sha256-<sha>-<tool>.json or sha256_<sha>-<tool>.json"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required for SBOM normalization."
  log_error "Install it with: sudo apt-get install -y jq"
  exit 1
fi

if ! jq empty "$SBOM_FILE" >/dev/null 2>&1; then
  log_error "SBOM is not valid JSON: $SBOM_FILE"
  exit 1
fi

if [ "$(jq -r '.bomFormat // empty' "$SBOM_FILE")" != "CycloneDX" ]; then
  log_error "SBOM is not in CycloneDX format."
  exit 1
fi

echo
echo "========== SBOM DEBUG =========="
echo "SBOM_FILE     : $SBOM_FILE"
echo "SBOM_FILENAME : $SBOM_FILENAME"
echo "ARTIFACT_SHA  : $ARTIFACT_SHA"
echo "SBOM_TOOL     : $SBOM_TOOL"
echo "================================"
echo

# sbom.json is the ONLY file sent to SSD.
# The original cdxgen file is left unchanged.
NORMALIZED_SBOM="$SBOM_DIR/sbom.json"
TMP_NORMALIZED="$SBOM_DIR/.sbom.json.tmp.$$"

log_info "Correcting cdxgen PURLs..."
log_info "Original SBOM will remain unchanged."
log_info "Creating corrected SBOM: $NORMALIZED_SBOM"

jq '
  def clean_purl:
    if type == "string" then
      split("?")[0] | split("#")[0]
    else .
    end;

  def corrected_maven:
    if ((.name // "") == "annotations-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-annotations-api", version:"9.0.88"}
    elif ((.name // "") == "catalina" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina", version:"9.0.88"}
    elif ((.name // "") == "catalina-ant" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina-ant", version:"9.0.88"} 
    elif ((.name // "") == "bootstrap:bootstrap" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-bootstrap", version:"9.0.88"}
    elif ((.name // "") == "catalina-ant:catalina-ant" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina-ant", version:"9.0.88"}
    elif ((.name // "") == "catalina-ha" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina-ha", version:"9.0.88"}
    elif ((.name // "") == "catalina-ssi" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina-ssi", version:"9.0.88"}
    elif ((.name // "") == "catalina-storeconfig" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-storeconfig", version:"9.0.88"}
    elif ((.name // "") == "catalina-tribes" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-catalina-tribes", version:"9.0.88"}
    elif ((.name // "") == "commons-daemon") then
      {group:"commons-daemon", name:"commons-daemon", version:(.version | tostring)}
    elif ((.name // "") | test("^ecj$|^ecj-")) and
         (((.version // "") | tostring) == "0549" or ((.version // "") | tostring) == "3.26.0.v20210609-0549") then
      {group:"org.eclipse.jdt.core.compiler", name:"ecj", version:"3.26.0"}
    elif ((.name // "") == "el-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-el-api", version:"9.0.88"}
    elif ((.name // "") == "jasper" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jasper", version:"9.0.88"}
    elif ((.name // "") == "jasper-el" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jasper-el", version:"9.0.88"}
    elif ((.name // "") == "jaspic-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jaspic-api", version:"9.0.88"}
    elif ((.name // "") == "jsp-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jsp-api", version:"9.0.88"}
    elif ((.name // "") == "servlet-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-servlet-api", version:"9.0.88"}
    elif ((.name // "") == "tomcat-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-api", version:"9.0.88"}
    elif ((.name // "") == "tomcat-coyote" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-coyote", version:"9.0.88"}
    elif ((.name // "") == "tomcat-dbcp" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-dbcp", version:"9.0.88"}
    elif ((.name // "") | test("^tomcat-i18n-")) and (.version // "") == "9.0.88" then
      {group:"org.apache.tomcat", name:(if (.name | contains(":")) then (.name | split(":")[0]) else .name end), version:"9.0.88"}
    elif ((.name // "") == "tomcat-jdbc" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jdbc", version:"9.0.88"}
    elif ((.name // "") == "tomcat-jni" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-jni", version:"9.0.88"}
    elif ((.name // "") == "tomcat-juli" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-juli", version:"9.0.88"}
    elif ((.name // "") == "tomcat-util" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-util", version:"9.0.88"}
    elif ((.name // "") == "tomcat-util-scan" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-util-scan", version:"9.0.88"}
    elif ((.name // "") == "tomcat-websocket" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-websocket", version:"9.0.88"}
    elif ((.name // "") == "websocket-api" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-websocket-api", version:"9.0.88"}
    elif ((.name // "") == "bootstrap" and (.version // "") == "9.0.88") then
      {group:"org.apache.tomcat", name:"tomcat-bootstrap", version:"9.0.88"}
    else null
    end;

  def canonical_purl($m):
    "pkg:maven/" + $m.group + "/" + $m.name + "@" + $m.version;

  def final_ref($c):
    ($c | corrected_maven) as $m
    | if $m != null then canonical_purl($m)
      elif ($c.purl? | type) == "string" then ($c.purl | clean_purl)
      elif ($c."bom-ref"? | type) == "string" then ($c."bom-ref" | clean_purl)
      else null end;

  # Build a mapping from every old component identifier to its final PURL.
  (.components // []) as $original
  | (reduce $original[] as $c
      ({};
       ($c | final_ref($c)) as $new
       | if $new != null then
           . + (
             [($c."bom-ref"? // empty), ($c.purl? // empty), ($c.packageUrl? // empty)]
             | map(select(type == "string"))
             | map({key:., value:$new})
             | from_entries
           )
         else . end
      )) as $refmap

  | if (.components? | type) == "array" then
      .components |= map(
        . as $c
        | ($c | corrected_maven) as $m
        | if $m != null then
            .group = $m.group
            | .name = $m.name
            | .version = $m.version
            | .purl = canonical_purl($m)
            | ."bom-ref" = .purl
            | if ."packageUrl"? != null then ."packageUrl" = .purl else . end
          else
            if (.purl? | type) == "string" then .purl |= clean_purl else . end
            | if (."packageUrl"? | type) == "string" then ."packageUrl" |= clean_purl else . end
            | if (."bom-ref"? | type) == "string" then ."bom-ref" |= clean_purl else . end
          end
      )
    else . end

  | if (.metadata.component? | type) == "object" then
      .metadata.component |= (
        if (.purl? | type) == "string" then .purl |= clean_purl else . end
        | if (."packageUrl"? | type) == "string" then ."packageUrl" |= clean_purl else . end
        | if (."bom-ref"? | type) == "string" then ."bom-ref" |= clean_purl else . end
      )
    else . end

  | if (.dependencies? | type) == "array" then
      .dependencies |= map(
        if (.ref? | type) == "string" then
          .ref = ($refmap[.ref] // (.ref | clean_purl))
        else . end
        | if (.dependsOn? | type) == "array" then
            .dependsOn |= map(
              if type == "string" then ($refmap[.] // (.|clean_purl)) else . end
            )
          else . end
      )
    else . end
' "$SBOM_FILE" > "$TMP_NORMALIZED"

if ! jq empty "$TMP_NORMALIZED" >/dev/null 2>&1; then
  rm -f "$TMP_NORMALIZED"
  log_error "Corrected SBOM is invalid JSON."
  exit 1
fi

# Final validation: no query string or fragment may remain in any
# PURL-like field handled by this script.
if jq -e '
  [
    .components[]?.purl?,
    .components[]?.packageUrl?,
    .components[]?."bom-ref"?,
    .metadata.component?.purl?,
    .metadata.component?.packageUrl?,
    .metadata.component?."bom-ref"?,
    .dependencies[]?.ref?,
    .dependencies[]?.dependsOn[]?
  ]
  | map(select(type == "string"))
  | any(.[]; test("[?#]"))
' "$TMP_NORMALIZED" >/dev/null 2>&1; then
  rm -f "$TMP_NORMALIZED"
  log_error "PURL validation failed: a query or fragment remains."
  exit 1
fi

mv "$TMP_NORMALIZED" "$NORMALIZED_SBOM"

log_success "Corrected SBOM created: $NORMALIZED_SBOM"

# --------------------------------------------------
# Upload ONLY sbom.json.
# cd into its directory so curl uses @sbom.json.
# --------------------------------------------------
ORIGINAL_DIR="$PWD"
cd "$SBOM_DIR"

echo
log_info "Uploading corrected sbom.json to SSD..."
sleep 5
curl --fail --silent --show-error --location \
  "${UPLOAD_URL}/webhook/api/v1/sbom?artifactName=${ARTIFACT_NAME}&artifactTag=${UNIQUE_ID}&artifactSha=${ARTIFACT_SHA}&tool=${SBOM_TOOL}" \
  --header "Content-Type: application/json" \
  --data-binary "@sbom.json" \
  --header "Authorization: Bearer ${SSD_TOKEN}"

log_success "sbom.json uploaded successfully."

cd "$ORIGINAL_DIR"

# --------------------------------------------------
# Send SSD webhook event.
# --------------------------------------------------
echo
log_info "Sending SSD webhook event..."

curl --fail --silent --show-error --location \
  "${UPLOAD_URL}/webhook/v1/ssd" \
  --header "X-OpsMx-Auth: ${SSD_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{
    \"jobname\": \"ssd-cli-scan\",
    \"buildnumber\": \"${UNIQUE_ID}\",
    \"joburl\": \"cli://local-scan\",
    \"gitcommit\": \"\",
    \"builduser\": \"scanner\",
    \"giturl\": \"${REPOSITORY_URL}\",
    \"gitbranch\": \"${BRANCH}\",
    \"artifactSha\": \"${ARTIFACT_SHA}\",
    \"artifacts\": [
      {
        \"nonimage\": \"${ARTIFACT_NAME}_${UNIQUE_ID}\"
      }
    ]
  }"

log_success "SSD webhook event sent successfully."

echo
echo "============================================================"
echo "                    SCAN COMPLETE"
echo "============================================================"
echo
log_info "Build ID      : $UNIQUE_ID"
log_info "Artifact Tag  : $UNIQUE_ID"
log_info "Artifact SHA  : $ARTIFACT_SHA"
log_info "SBOM Tool     : $SBOM_TOOL"
log_info "Original SBOM : $SBOM_FILE"
log_info "Uploaded SBOM : $SBOM_DIR/sbom.json"
