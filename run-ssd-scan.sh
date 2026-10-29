#!/bin/bash
# Scans source code or a container image with the SSD scanner CLI and submits the results to SSD.
# Usage: SSD_UPLOAD_URL=https://<ssd-host> SSD_TOKEN=<team-token> ./run-ssd-scan.sh <target>
#   /path/to/repo            source-code folder (a git clone; for a plain folder also set REPO_URL)
#   /path/to/source.tar.gz   source-code archive: .tar, .tar.gz or .tgz (set REPO_URL)
#   /path/to/image.tar       container image saved with: docker save <image> -o image.tar
#   <image>:<tag>            container image already on this machine (saved to a temporary tar first)
# Optional: REPO_URL, BRANCH_NAME (default main), SBOM_TOOLS (default cdxgen,syft), SCANNERS, CLI_IMAGE.
# The script does not wait for SSD: it exits once the scan is submitted. SSD then processes it and shows the results in the UI.
set -uo pipefail

TARGET="${1:-}"
CLI_IMAGE="${CLI_IMAGE:-docker.io/opsmx11/ssd-scanner-cli:v0.6.17}"
# SSD reads the SBOM of the tool the team selected, so both common SBOM tools run by default
SBOM_TOOLS="${SBOM_TOOLS:-cdxgen,syft}"
WORK_DIR=""

fail() { echo "[ERROR] $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
cleanup() { [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

[ -n "$TARGET" ] || fail "Nothing to scan. Usage: ./run-ssd-scan.sh <source folder | source .tar/.tar.gz | image .tar | image:tag>"
[ -n "${SSD_UPLOAD_URL:-}" ] || fail "Set SSD_UPLOAD_URL to your SSD address: export SSD_UPLOAD_URL=https://<ssd-host>"
[ -n "${SSD_TOKEN:-}" ] || fail "Set SSD_TOKEN to your SSD team token: export SSD_TOKEN='...'"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed."
docker info >/dev/null 2>&1 || fail "Docker is not running, or this user can't use it."

STAMP="$(date +%Y%m%d%H%M%S)"
SRC=""
if [ -d "$TARGET" ]; then
  MODE=source
  SRC="$(cd "$TARGET" && pwd)"
  [ -n "$(ls -A "$SRC" 2>/dev/null)" ] || fail "$SRC is empty or not readable."
  { [ -f "$SRC/manifest.json" ] || [ -f "$SRC/oci-layout" ]; } && fail "$SRC is an unpacked container image. Pass the original .tar instead."
elif [ -f "$TARGET" ]; then
  FILE_DIR="$(cd "$(dirname "$TARGET")" && pwd)"
  FILE="$(basename "$TARGET")"
  LIST="$(tar -tf "$FILE_DIR/$FILE" 2>/dev/null)" || fail "$FILE is not a tar archive. Pass a folder, a .tar/.tar.gz/.tgz, or an image name."
  # A container image tar has manifest.json or oci-layout at its root; anything else is source code
  if grep -qE '^(\./)?(manifest\.json|oci-layout)$' <<<"$LIST"; then
    MODE=image
    case "$FILE" in *.tar) ;; *) fail "A container image must be a plain .tar (docker save <image> -o image.tar), not $FILE." ;; esac
    case "$FILE" in *[!A-Za-z0-9._-]*) fail "Rename $FILE to use only letters, digits, '.', '_' and '-'." ;; esac
  else
    MODE=source
  fi
elif docker image inspect "$TARGET" >/dev/null 2>&1; then
  MODE=image
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssd-scan-XXXXXX")"
  FILE_DIR="$WORK_DIR"
  FILE="$(printf '%s' "${TARGET##*/}" | tr -c 'A-Za-z0-9._-' '-').tar"
  echo "Saving image $TARGET to a temporary tar..."
  docker save "$TARGET" -o "$FILE_DIR/$FILE" || fail "Could not save image $TARGET."
  chmod a+rx "$WORK_DIR" && chmod a+r "$FILE_DIR/$FILE"
else
  fail "$TARGET is not a folder, a file, or an image on this machine (for a registry image run 'docker pull $TARGET' first)."
fi

if [ "$MODE" = source ]; then
  IS_GIT=0
  [ -n "$SRC" ] && git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1
  # Remote URL without credentials, as https
  url="${REPO_URL:-}"
  [ -n "$url" ] || [ "$IS_GIT" -eq 0 ] || url="$(git -C "$SRC" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] || fail "Can't tell which repository this is. Set REPO_URL to its https URL, e.g. export REPO_URL=https://github.com/<org>/<repo>"
  url="$(printf '%s' "$url" | sed -E 's#^[^@/]+@([^:/]+):#https://\1/#; s#^ssh://[^@/]+@([^/:]+)(:[0-9]+)?/#https://\1/#; s#^(https?://)[^@/]+@#\1#; s#\.git$##; s#^https://(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)/v3/([^/]+)/([^/]+)/([^/]+)$#https://dev.azure.com/\2/\3/_git/\4#')"
  BRANCH=""
  [ "$IS_GIT" -eq 0 ] || BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  { [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; } && BRANCH="${BRANCH_NAME:-main}"
  COMMIT=local
  [ "$IS_GIT" -eq 0 ] || COMMIT="$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null || echo local)"
  # No dots in the name (SSD would read Contoso.Web as a file extension) and a version unique per run
  NAME="$(printf '%s' "$(basename "$url")" | tr -c 'A-Za-z0-9-' '-')"
  VERSION="$COMMIT-$STAMP"
  # SSD keys an extension-less artifact on sha256("<name>_<version>"), so the results link is known up front
  SHA="$(printf '%s_%s' "$NAME" "$VERSION" | sha256)"

  # Scan a world-readable copy: the scanner runs as another user in the container, and the original stays untouched
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssd-scan-XXXXXX")"
  if [ -n "$SRC" ]; then
    cp -a "$SRC/." "$WORK_DIR/" || fail "Could not copy $SRC."
  else
    tar -xf "$FILE_DIR/$FILE" -C "$WORK_DIR" || fail "Could not extract $FILE."
  fi
  chmod -R a+rX "$WORK_DIR"
  SOURCE_DIR="$WORK_DIR"
  # An archive that wraps everything in one top-level folder is scanned from inside that folder
  TOP="$(ls -A "$WORK_DIR")"
  [ "$(grep -c . <<<"$TOP")" -eq 1 ] && [ -d "$WORK_DIR/$TOP" ] && [ -z "$SRC" ] && SOURCE_DIR="$WORK_DIR/$TOP"
  [ -n "$(ls -A "$SOURCE_DIR")" ] || fail "No source files found to scan."
  SCANNERS="${SCANNERS:-$SBOM_TOOLS,trivy,opengrep}"
  SHOWN="$NAME:$VERSION"
else
  VERSION="$STAMP"
  # The image keeps its .tar name: SSD keys it on sha256("<file>:<tag>") unless the tag is already in the file name
  case "$FILE" in *"$VERSION"*) SHA="$(printf '%s' "$FILE" | sha256)" ;; *) SHA="$(printf '%s:%s' "$FILE" "$VERSION" | sha256)" ;; esac
  SCANNERS="${SCANNERS:-$SBOM_TOOLS}"
  SHOWN="${FILE%.tar}:$VERSION"
fi

LOG="$(mktemp -t ssd-scan.XXXXXX.log)"
LINK="${SSD_UPLOAD_URL%/}/ui/artifact-security/generated?artifactSha=sha256%3A$SHA"

echo "============================================================"
echo " SSD $MODE scan"
if [ "$MODE" = source ]; then
  echo "  repository : $url"
  echo "  path       : ${SRC:-$FILE_DIR/$FILE}"
  echo "  branch     : $BRANCH"
else
  echo "  image tar  : $FILE"
fi
echo "  artifact   : $SHOWN"
echo "  scanners   : $SCANNERS"
echo "  SSD        : $SSD_UPLOAD_URL"
echo "  image      : $CLI_IMAGE"
echo "============================================================"

if [ "$MODE" = source ]; then
  docker run --rm \
    -v "$SOURCE_DIR:/home/scanner/source" \
    "$CLI_IMAGE" \
      --scanners="$SCANNERS" \
      --cdxgen-scanners=sourcecodesbom \
      --syft-scanners=sourcecodesbom \
      --grype-scanners=sourcecodesbom \
      --grype-include-locations=false \
      --trivy-scanners=codelicensescan,codesecretscan \
      --source-code-path=/home/scanner/source \
      --artifact-type=file \
      --artifact-path=/home/scanner/source \
      --artifact-name="$NAME" \
      --artifact-tag="$VERSION" \
      --repository-url="$url" \
      --branch="$BRANCH" \
      --build-id="$STAMP" \
      --upload-url="$SSD_UPLOAD_URL" \
      --ssd-token="$SSD_TOKEN" 2>&1 | tee "$LOG"
else
  # --artifact-type=tar reads the image archive; grype must emit CycloneDX (include-locations=false) or SSD rejects it
  docker run --rm \
    -v "$FILE_DIR:/home/scanner/source" \
    "$CLI_IMAGE" \
      --scanners="$SCANNERS" \
      --cdxgen-scanners=sbom \
      --syft-scanners=sbom \
      --grype-scanners=sbom \
      --grype-include-locations=false \
      --source-code-path=/home/scanner/source \
      --artifact-type=tar \
      --artifact-path="/home/scanner/source/$FILE" \
      --artifact-name="$FILE" \
      --artifact-tag="$VERSION" \
      --build-id="$STAMP" \
      --upload-url="$SSD_UPLOAD_URL" \
      --ssd-token="$SSD_TOKEN" 2>&1 | tee "$LOG"
fi
RC=${PIPESTATUS[0]}

PLAIN="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG")"
echo "============================================================"
[ "$RC" -eq 0 ] || { echo " FAILED: the scanner exited with code $RC"; echo " log: $LOG"; exit "$RC"; }
# The scanner exits 0 even when SSD rejects the scan, so check that the build event was accepted
if ! printf '%s\n' "$PLAIN" | grep -q 'Successfully sent build event'; then
  echo " FAILED: SSD did not accept the scan (check the token and that SSD is reachable)"; echo " log: $LOG"; exit 1
fi
echo " SUBMITTED: $SHOWN"
echo " SSD is processing it now; results appear in the UI in a few minutes:"
echo "   $LINK"
echo " log: $LOG"
