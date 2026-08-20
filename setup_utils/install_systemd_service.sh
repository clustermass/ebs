#!/bin/bash
# Render and install the EBS systemd unit and its scoped sudoers permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/ebs.service.template"
SERVICE_TARGET="/etc/systemd/system/ebs.service"
SUDOERS_TARGET="/etc/sudoers.d/ebs"
SERVICE_USER="${SUDO_USER:-$(id -un)}"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
MOUNT_BIN="$(command -v mount)"
UMOUNT_BIN="$(command -v umount)"
TEMP_SERVICE=""
TEMP_SUDOERS=""

cleanup() {
  [ -z "$TEMP_SERVICE" ] || rm -f "$TEMP_SERVICE"
  [ -z "$TEMP_SUDOERS" ] || rm -f "$TEMP_SUDOERS"
}
trap cleanup EXIT

fail() {
  echo "Error: $1" >&2
  exit 1
}

case "$PROJECT_DIR" in
  *[[:space:]]*) fail "the EBS installation path must not contain whitespace: $PROJECT_DIR" ;;
esac

[ -f "$TEMPLATE_FILE" ] || fail "service template not found: $TEMPLATE_FILE"
[ -x "$PROJECT_DIR/ebs.sh" ] || fail "ebs.sh is not executable; run setup_permissions.sh first"
[ -f "$PROJECT_DIR/config.json" ] || fail "config.json not found in $PROJECT_DIR"
[ -x "$PROJECT_DIR/bin/jq-linux64" ] || fail "bundled jq is not executable"
command -v sudo >/dev/null 2>&1 || fail "sudo is required"
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"
command -v visudo >/dev/null 2>&1 || fail "visudo is required; install sudo"
"$PROJECT_DIR/bin/jq-linux64" empty "$PROJECT_DIR/config.json" || \
  fail "config.json is not valid JSON"

if [ ! -r "$PROJECT_DIR/config.json" ] || [ ! -w "$PROJECT_DIR" ]; then
  fail "$SERVICE_USER must be able to read config.json and write to $PROJECT_DIR"
fi

chmod 600 "$PROJECT_DIR/config.json"
mkdir -p "$PROJECT_DIR/excluded_machines" \
  "$PROJECT_DIR/processed_machines" "$PROJECT_DIR/mount"

cache_mount_requirement=""
temp_storage_machine_count=$("$PROJECT_DIR/bin/jq-linux64" \
  '[.machines[] | select(.useTempBackupStorage == "y")] | length' \
  "$PROJECT_DIR/config.json")

if [ "$temp_storage_machine_count" -gt 0 ]; then
  cache_path=$("$PROJECT_DIR/bin/jq-linux64" -r \
    '.commonConfig.tempBackupStoragePath // empty' "$PROJECT_DIR/config.json")
  [ -n "$cache_path" ] || fail "tempBackupStoragePath is required when local caching is enabled"
  case "$cache_path" in
    /*) ;;
    *) fail "tempBackupStoragePath must be an absolute path: $cache_path" ;;
  esac
  case "$cache_path" in
    *[[:space:]]*) fail "tempBackupStoragePath must not contain whitespace: $cache_path" ;;
  esac
  [ -d "$cache_path" ] || fail "cache directory does not exist: $cache_path"
  [ -w "$cache_path" ] || fail "$SERVICE_USER cannot write to cache: $cache_path"
  cache_mount_requirement="RequiresMountsFor=$cache_path"
fi

service_content=$(<"$TEMPLATE_FILE")
service_content=${service_content//@EBS_USER@/$SERVICE_USER}
service_content=${service_content//@EBS_GROUP@/$SERVICE_GROUP}
service_content=${service_content//@EBS_PROJECT_DIR@/$PROJECT_DIR}
service_content=${service_content//@CACHE_MOUNT_REQUIREMENT@/$cache_mount_requirement}

TEMP_SERVICE=$(mktemp --suffix=.service)
printf '%s\n' "$service_content" > "$TEMP_SERVICE"
chmod 644 "$TEMP_SERVICE"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$TEMP_SERVICE" || fail "generated systemd unit is invalid"
fi

TEMP_SUDOERS=$(mktemp)
cat > "$TEMP_SUDOERS" <<EOF
# Managed by $PROJECT_DIR/setup_utils/install_systemd_service.sh
# Allow EBS to mount CIFS shares and unmount only beneath its mount directory.
$SERVICE_USER ALL=(root) NOPASSWD: $MOUNT_BIN -t cifs -o * * $PROJECT_DIR/mount/*
$SERVICE_USER ALL=(root) NOPASSWD: $UMOUNT_BIN $PROJECT_DIR/mount/*
$SERVICE_USER ALL=(root) NOPASSWD: $UMOUNT_BIN -f $PROJECT_DIR/mount/*
EOF
chmod 440 "$TEMP_SUDOERS"

visudo -cf "$TEMP_SUDOERS" >/dev/null || fail "generated sudoers rules are invalid"

echo "Installing EBS for: $SERVICE_USER:$SERVICE_GROUP"
echo "Project directory:  $PROJECT_DIR"
echo "Systemd unit:       $SERVICE_TARGET"
echo "Sudoers rules:      $SUDOERS_TARGET"

sudo install -o root -g root -m 0644 "$TEMP_SERVICE" "$SERVICE_TARGET"
sudo install -o root -g root -m 0440 "$TEMP_SUDOERS" "$SUDOERS_TARGET"
sudo systemctl daemon-reload
sudo systemctl enable ebs.service

echo
echo "EBS systemd installation completed and the service is enabled at boot."
echo "The service was not started automatically."
echo
echo "Review the rendered unit:"
echo "  systemctl cat ebs.service"
echo
echo "Start and monitor EBS when ready:"
echo "  sudo systemctl start ebs.service"
echo "  systemctl status ebs.service"
echo "  journalctl -u ebs.service -f"
