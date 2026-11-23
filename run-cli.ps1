
$ErrorActionPreference = "Stop"

# --------------------------------------------------
# Logging functions
# --------------------------------------------------

function Log-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Log-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Log-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Log-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

try {

    # --------------------------------------------------
    # Default source directory = current directory
    # Optional custom path can be passed as argument
    # --------------------------------------------------

    if ($args.Count -gt 0) {
        $SOURCE_DIR = $args[0]
    }
    else {
        $SOURCE_DIR = (Get-Location).Path
    }

    $SOURCE_DIR = (Resolve-Path -LiteralPath $SOURCE_DIR).Path

    $ARTIFACT_NAME = Split-Path $SOURCE_DIR -Leaf

    $REPOSITORY_URL = "https://OpsMx-POC@dev.azure.com/OpsMx-POC/ask/_git/ask"
    $BRANCH = "master"
    $UPLOAD_URL = "https://iifl.ssdpoc.opsmx.net"
    $CLI_IMAGE = "docker.io/opsmx11/ssd-scanner-cli:v0.6.9"
    $TOOL = "azure"

    # Token must be set before execution
    $SSD_TOKEN = $env:SSD_TOKEN

    # Auto-generate unique build ID and artifact tag
    $UNIQUE_ID = Get-Date -Format "yyyyMMddHHmmss"

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "        OpsMx Delivery Shield - PoC Scan Runner"
    Write-Host "============================================================"
    Write-Host ""

    Log-Info "Source directory : $SOURCE_DIR"
    Log-Info "Artifact name    : $ARTIFACT_NAME"
    Log-Info "Build ID         : $UNIQUE_ID"
    Log-Info "Artifact Tag     : $UNIQUE_ID"

    Write-Host ""
    Log-Info "Performing pre-flight checks..."

    # --------------------------------------------------
    # Check source directory
    # --------------------------------------------------

    if (-not (Test-Path -LiteralPath $SOURCE_DIR -PathType Container)) {
        throw "Source directory does not exist: $SOURCE_DIR"
    }

    if (-not (Get-Item -LiteralPath $SOURCE_DIR).Attributes) {
        throw "Source directory is not accessible."
    }

    $FILES = Get-ChildItem -LiteralPath $SOURCE_DIR -Force

    if ($FILES.Count -eq 0) {
        throw "Source directory is empty: $SOURCE_DIR"
    }

    # --------------------------------------------------
    # Check Docker installation
    # --------------------------------------------------

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not available in PATH."
    }

    # --------------------------------------------------
    # Check Docker daemon
    # --------------------------------------------------

    docker info *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker daemon is not running or current user cannot access Docker. Start Docker Desktop."
    }

    # --------------------------------------------------
    # Check SSD token
    # --------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SSD_TOKEN)) {
        throw @"
SSD_TOKEN is not set.

Please export the token before running the scan:

`$env:SSD_TOKEN = "your-token-here"
.\run-ssd-scan.ps1
"@
    }

    # --------------------------------------------------
    # Pull SSD CLI image
    # --------------------------------------------------

    Log-Info "Pulling SSD CLI image: $CLI_IMAGE"

    docker pull $CLI_IMAGE

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to pull Docker image."
    }

    Log-Success "Pre-flight checks completed successfully."

    Write-Host ""
    Log-Info "Starting SSD scan..."

    # --------------------------------------------------
    # Execute SSD scan
    # --------------------------------------------------

    docker run --rm `
        -v "${SOURCE_DIR}:/home/scanner/source:rw" `
        $CLI_IMAGE `
        --scanners=cdxgen,opengrep,trivy `
        --cdxgen-scanners=sourcecodesbom `
        --trivy-scanners=codelicensescan,codesecretscan `
        --source-code-path=/home/scanner/source `
        --repository-url="$REPOSITORY_URL" `
        --branch="$BRANCH" `
        --build-id="$UNIQUE_ID" `
        --upload-url="$UPLOAD_URL" `
        --offline-mode=false `
        --artifact-type=file `
        --artifact-name="$ARTIFACT_NAME" `
        --artifact-path=/home/scanner/source `
        --keep-results=true `
        --debug=false `
        --artifact-tag="$UNIQUE_ID" `
        --ssd-token="$SSD_TOKEN"

    if ($LASTEXITCODE -ne 0) {
        throw "SSD scan execution failed. Docker exit code: $LASTEXITCODE"
    }

    Write-Host ""
    Log-Success "SSD scan completed successfully."
    Log-Info "Build ID     : $UNIQUE_ID"
    Log-Info "Artifact Tag : $UNIQUE_ID"

}
catch {
    Write-Host ""
    Log-Error $_.Exception.Message
    exit 1
}
