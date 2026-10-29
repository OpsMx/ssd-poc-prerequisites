# OpsMx Delivery Shield - PoC Scan Runner

Scripts to check a PoC machine and run OpsMx Delivery Shield (SSD) scans with the SSD scanner CLI.

## Files

- `opsmx_prereq_check_CLI.sh` - checks the machine and network prerequisites
- `run-ssd-scan.sh` - scans source code or a container image and submits the results to SSD

## Get the latest scripts

```bash
git clone https://github.com/OpsMx/ssd-poc-prerequisites.git
cd ssd-poc-prerequisites
chmod +x *.sh
```

Or download only the scan script:
```bash
curl -fsSLO https://raw.githubusercontent.com/OpsMx/ssd-poc-prerequisites/main/run-ssd-scan.sh && chmod +x run-ssd-scan.sh
```

## Prerequisites

- Linux or macOS with Docker installed and running
- Internet access to Docker Hub and to the SSD URL

```bash
./opsmx_prereq_check_CLI.sh
```

## Run a scan

```bash
export SSD_UPLOAD_URL=https://<ssd-host>
export SSD_TOKEN='<team-token>'

./run-ssd-scan.sh /path/to/repo           # source-code folder (git clone)
./run-ssd-scan.sh /path/to/source.tar.gz  # source-code archive: .tar, .tar.gz or .tgz
./run-ssd-scan.sh /path/to/image.tar      # container image: docker save <image> -o image.tar
./run-ssd-scan.sh myapp:1.0               # container image already on this machine
```

For a source folder that is not a git clone, or a source archive, also set the repository it came from:
```bash
export REPO_URL=https://github.com/<org>/<repo>
export BRANCH_NAME=main
```

Optional settings:

| Variable | Default | Purpose |
|---|---|---|
| `SBOM_TOOLS` | `cdxgen,syft` | SBOM tools to run; SSD uses the one selected for the team (e.g. `SBOM_TOOLS=cdxgen`) |
| `SCANNERS` | source: `cdxgen,syft,trivy,opengrep`; image: `cdxgen,syft` | full scanner list |
| `CLI_IMAGE` | `docker.io/opsmx11/ssd-scanner-cli:v0.6.17` | scanner image |

The script exits once SSD accepts the scan and prints a link to the results, which appear in the UI a few minutes later. C# scans take longer (about 7-8 minutes) because the scanner downloads a .NET SDK first.

## Common errors

| Message | Fix |
|---|---|
| `Set SSD_UPLOAD_URL ...` / `Set SSD_TOKEN ...` | export both variables before running |
| `Docker is not running, or this user can't use it.` | `sudo systemctl start docker`, or add the user to the `docker` group |
| `Can't tell which repository this is.` | set `REPO_URL` |
| `SSD did not accept the scan` | check the token and that the SSD URL is reachable; the log path is printed |
