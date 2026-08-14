#!/usr/bin/env bash

# OpsMx Delivery Shield - Linux Prerequisite & Network Validation Script
# Customer-facing script for validating PoC readiness.

GREEN="\e[32m"
RED="\e[31m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

pass_icon="${GREEN}✔ Met${RESET}"
fail_icon="${RED}✘ Not Met${RESET}"

print_row() {
  printf "%-35s %-28b %s\n" "$1" "$2" "$3"
}

check_url() {
  local label="$1"
  local host="$2"

  # DNS check
  if ! getent hosts "$host" >/dev/null 2>&1; then
    print_row "$label" "$fail_icon" "DNS resolution failed / not whitelisted"
    return
  fi

  # HTTPS connectivity check
  if curl -Is --connect-timeout 10 --max-time 15 "https://$host" >/dev/null 2>&1; then
    print_row "$label" "$pass_icon" "Accessible from server"
  else
    print_row "$label" "$fail_icon" "Not reachable from server"
  fi
}

echo -e "${BOLD}OpsMx Delivery Shield - PoC Prerequisite Validation${RESET}"
echo "Generated on: $(date)"
echo

printf "%-35s %-28s %s\n" "Category" "Pre-Requisite Status" "Comment"
printf "%-35s %-28s %s\n" "-----------------------------------" "----------------------------" "---------------------------------------------"

# Operating System
os_name=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
arch=$(uname -m)

if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
  print_row "Operating System" "$pass_icon" "$os_name ($arch)"
else
  print_row "Operating System" "$fail_icon" "64-bit amd64 recommended, found $arch"
fi

# Docker
if command -v docker >/dev/null 2>&1; then
  docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  if docker info >/dev/null 2>&1; then
    print_row "Docker" "$pass_icon" "Docker $docker_version installed and running"
  else
    print_row "Docker" "$fail_icon" "Docker installed but daemon is not running"
  fi
else
  print_row "Docker" "$fail_icon" "Docker is not installed"
fi

# Logged-in user sudo access
current_user=$(whoami)

if sudo -n true >/dev/null 2>&1; then
  print_row "Sudo Access" "$pass_icon" "User '$current_user' has sudo access"
else
  if groups "$current_user" | grep -Eq '\b(sudo|wheel)\b'; then
    print_row "Sudo Access" "$pass_icon" "User '$current_user' is in sudo/wheel group"
  else
    print_row "Sudo Access" "$fail_icon" "User '$current_user' does not have sudo access"
  fi
fi

# Docker group access
if groups "$current_user" | grep -qw docker; then
  print_row "Docker Group Access" "$pass_icon" "User '$current_user' is in docker group"
else
  print_row "Docker Group Access" "$fail_icon" "User '$current_user' is not in docker group"
fi

# CPU
vcpus=$(nproc)
if [[ $vcpus -ge 8 ]]; then
  print_row "CPU" "$pass_icon" "Available: ${vcpus} vCPU"
else
  print_row "CPU" "$fail_icon" "Minimum 8 vCPU required, available: ${vcpus}"
fi

# Memory
mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
if awk "BEGIN {exit !($mem_gb >= 16)}"; then
  print_row "Memory" "$pass_icon" "Available RAM: ${mem_gb} GB"
else
  print_row "Memory" "$fail_icon" "Minimum 16 GB required, available: ${mem_gb} GB"
fi

# Disk Space
disk_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
if [[ $disk_gb -ge 200 ]]; then
  print_row "Disk Space" "$pass_icon" "Free space: ${disk_gb} GB"
else
  print_row "Disk Space" "$fail_icon" "Minimum 200 GB required, free: ${disk_gb} GB"
fi

echo
echo -e "${BOLD}URL Whitelisting / Connectivity Validation${RESET}"

printf "%-35s %-28s %s\n" "URL / Host" "Status" "Comment"
printf "%-35s %-28s %s\n" "-----------------------------------" "----------------------------" "---------------------------------------------"

check_url "customer-poc-demo.ssd-sandbox.opsmx.org" "customer-poc-demo.ssd-sandbox.opsmx.org"
check_url "builds.dotnet.microsoft.com" "builds.dotnet.microsoft.com"
check_url "registry-1.docker.io" "registry-1.docker.io"
check_url "auth.docker.io" "auth.docker.io"
check_url "production.cloudflare.docker.com" "production.cloudflare.docker.com"

echo
echo -e "${BLUE}Legend:${RESET} ${GREEN}✔ Met${RESET}  ${RED}✘ Not Met${RESET}"
echo
echo "Please share the complete output with the OpsMx team before the PoC session."
