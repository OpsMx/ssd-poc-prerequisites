# OpsMx Delivery Shield - PoC Scan Runner

This package provides a simplified and customer-friendly way to trigger an OpsMx Delivery Shield (SSD) source scan during a PoC.

The script automatically:

- Generates a unique **Build ID**
- Generates a unique **Artifact Tag**
- Validates **sudo access**
- Validates **Docker installation**
- Validates **Docker daemon access**
- Validates **source directory**
- Validates **SSD token configuration**
- Pulls the required SSD CLI image
- Displays clear success and error messages

---

## Files

- `run-ssd-scan.sh` - Main scan script
- `README.md` - This document

---

## Prerequisites

- Ubuntu 20.04 or later
- Docker installed and running
- Internet access to pull Docker images
- Internet access to reach the SSD upload URL
- Source code available on the VM

---

## Step 1: Download the package

Copy both files to the Linux VM where the scan will be executed.

---

## Step 2: Configure the SSD token

Open the script:

```bash
vi run-ssd-scan.sh
```

Find:

```bash
SSD_TOKEN="${SSD_TOKEN:-REPLACE_WITH_SSD_TOKEN}"
```

Replace `REPLACE_WITH_SSD_TOKEN` with the token shared by the OpsMx team.

Save and exit.

---

## Step 3: Make the script executable

```bash
chmod +x run-ssd-scan.sh
```

---

## Step 4: Run the scan

### Option A - Use default source path

Default path:

```bash
/root/SunSystems
```

Run:

```bash
./run-ssd-scan.sh
```

### Option B - Provide a custom source path

```bash
./run-ssd-scan.sh /path/to/source-code
```

Example:

```bash
./run-ssd-scan.sh /home/ubuntu/my-application
```

---

## What the script does

### Pre-flight checks

- Checks whether the user has sudo access
- Checks whether the source directory exists
- Checks whether the source directory is readable
- Checks whether the source directory is not empty
- Checks whether Docker is installed
- Checks whether Docker daemon is running
- Checks whether SSD token is configured
- Verifies connectivity to the SSD endpoint (best effort)

### Scan execution

- Pulls the latest SSD CLI image
- Mounts the source directory
- Generates a timestamp-based Build ID
- Generates a timestamp-based Artifact Tag
- Uploads results to the SSD server

---

## Example output

```text
[INFO] Source directory : /root/SunSystems
[INFO] Build ID         : 20260814104530
[INFO] Artifact Tag     : 20260814104530

[INFO] Performing pre-flight checks...
[INFO] Sudo access: available
[SUCCESS] Pre-flight checks completed successfully.

[INFO] Starting SSD scan...

[SUCCESS] SSD scan completed successfully.
```

---

## Common errors

### Docker is not installed

```text
[ERROR] Docker is not installed or not available in PATH.
```

Install Docker and retry.

### Docker daemon not running

```text
[ERROR] Docker daemon is not running or current user cannot access Docker.
```

Start Docker:

```bash
sudo systemctl start docker
```

### Source directory missing

```text
[ERROR] Source directory does not exist.
```

Verify the path and run again.

### Source directory empty

```text
[ERROR] Source directory is empty.
```

Ensure the application source code is present.

### SSD token not configured

```text
[ERROR] SSD token is not configured.
```

Edit the script and add the token.

---

## Notes

- Build ID and Artifact Tag are generated automatically using the current timestamp.
- No manual update is required for repeated scans.
- Results are uploaded to the SSD dashboard configured for this PoC.
