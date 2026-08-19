#!/bin/bash
# Verify commands required by the active EBS workflow on Ubuntu.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

required_commands=(
  awk
  base64
  ex
  mount.cifs
  mountpoint
  ping
  plink
  ssh
  ssh-keygen
  ssh-keyscan
  sshpass
  sudo
  timeout
  umount
  wakeonlan
)

missing_count=0

echo "Checking EBS system dependencies..."

for command_name in "${required_commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '  OK      %s\n' "$command_name"
  else
    printf '  MISSING %s\n' "$command_name"
    missing_count=$((missing_count + 1))
  fi
done

if [ -x "$PROJECT_DIR/bin/ovftool/ovftool" ]; then
  printf '  OK      %s\n' "ovftool (local bin/ovftool)"
elif command -v ovftool >/dev/null 2>&1; then
  printf '  OK      %s\n' "ovftool (PATH)"
else
  printf '  MISSING %s\n' "ovftool"
  missing_count=$((missing_count + 1))
fi

echo
if [ "$missing_count" -ne 0 ]; then
  echo "Dependency check failed: $missing_count command(s) missing."
  echo "Install the Ubuntu packages listed in INSTALLATION, then run this again."
  exit 1
fi

echo "All required EBS system dependencies are available."
exit 0
