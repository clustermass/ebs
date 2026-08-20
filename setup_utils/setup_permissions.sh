#!/bin/bash
# Sets +x for all files required by EBS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FILES=(
  "ebs.sh"
  "mount_share.sh"
  "power_off_synology.sh"
  "power_on_synology.sh"
  "process_machine.sh"
  "report_error.sh"
  "unmount_share.sh"
  "setup_utils/setup_permissions.sh"
  "setup_utils/get_server_signature.sh"
  "setup_utils/update_esxi_host_keys.sh"
  "setup_utils/test_backup_servers.sh"
  "setup_utils/check_dependencies.sh"
  "setup_utils/test_esxi_servers.sh"
  "setup_utils/test_nas_power.sh"
  "setup_utils/install_systemd_service.sh"
  "bin/jq-linux64"
  "bin/ovftool/ovftool"
)

echo "Setting executable bit on EBS files in: $PROJECT_DIR"

for f in "${FILES[@]}"; do
  if [ -f "$PROJECT_DIR/$f" ]; then
    chmod +x "$PROJECT_DIR/$f"
    echo "  +x $f"
  else
    echo "  (skip) $f not found"
  fi
done

echo "Done."
