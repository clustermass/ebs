#!/bin/bash
# Validate every backupServers entry by mounting its CIFS share, performing a
# small write/delete probe, and unmounting it through the production helpers.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JQ_BIN="$PROJECT_DIR/bin/jq-linux64"
MOUNT_HELPER="$PROJECT_DIR/mount_share.sh"
UNMOUNT_HELPER="$PROJECT_DIR/unmount_share.sh"
CONFIG_FILE="${1:-$PROJECT_DIR/config.json}"
TEST_ROOT="$PROJECT_DIR/mount/setup_validation"
CURRENT_MOUNT_PATH=""

fail() {
  echo "Error: $1" >&2
  exit 1
}

cleanup_current_mount() {
  if [ -z "$CURRENT_MOUNT_PATH" ]; then
    return
  fi

  if mountpoint -q "$CURRENT_MOUNT_PATH"; then
    "$UNMOUNT_HELPER" "$CURRENT_MOUNT_PATH" >/dev/null 2>&1 || true
  elif [ -d "$CURRENT_MOUNT_PATH" ]; then
    rmdir "$CURRENT_MOUNT_PATH" >/dev/null 2>&1 || true
  fi
  CURRENT_MOUNT_PATH=""
}

trap cleanup_current_mount EXIT
trap 'cleanup_current_mount; exit 130' INT TERM

[ -x "$JQ_BIN" ] || fail "bundled jq is not executable: $JQ_BIN"
[ -x "$MOUNT_HELPER" ] || fail "mount helper is not executable: $MOUNT_HELPER"
[ -x "$UNMOUNT_HELPER" ] || fail "unmount helper is not executable: $UNMOUNT_HELPER"
[ -f "$CONFIG_FILE" ] || fail "configuration file not found: $CONFIG_FILE"
command -v mountpoint >/dev/null 2>&1 || fail "mountpoint is missing; install util-linux"
command -v mount.cifs >/dev/null 2>&1 || fail "mount.cifs is missing; install cifs-utils"
"$JQ_BIN" empty "$CONFIG_FILE" || fail "configuration is not valid JSON: $CONFIG_FILE"

server_count=$("$JQ_BIN" '.backupServers | length' "$CONFIG_FILE")
[ "$server_count" -gt 0 ] || fail "no servers were found in .backupServers"

mkdir -p "$TEST_ROOT"

echo "Synology/CIFS backup-share validation"
echo "Configuration: $CONFIG_FILE"
echo "Shares found: $server_count"
echo "Each NAS must already be powered on and reachable."

passed_count=0
failed_count=0
server_index=0

while IFS= read -r encoded_server; do
  server_index=$((server_index + 1))
  server_json=$(printf '%s' "$encoded_server" | base64 --decode)
  server_name=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.name // empty')
  server_ip=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.ip // empty')
  server_login=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.login // empty')
  server_password=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.password // empty')
  share_path=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.sharePath // empty')

  echo
  echo "[$server_index/$server_count] Testing: ${server_name:-unnamed backup server}"

  if [ -z "$server_name" ] || [ -z "$server_ip" ] || \
     [ -z "$server_login" ] || [ -z "$server_password" ] || \
     [ -z "$share_path" ]; then
    echo "FAILED: name, ip, login, password, and sharePath are all required."
    failed_count=$((failed_count + 1))
    continue
  fi

  safe_name=$(printf '%s' "$server_name" | tr -cd '[:alnum:]_.-')
  [ -n "$safe_name" ] || safe_name="server-$server_index"
  CURRENT_MOUNT_PATH="$TEST_ROOT/${safe_name}-${server_index}-$$"
  remote_share="//$server_ip/$share_path"

  echo "Share: $remote_share"
  echo "Mounting with mount_share.sh..."
  "$MOUNT_HELPER" "$CURRENT_MOUNT_PATH" "$remote_share" \
    "$server_login" "$server_password" >/dev/null

  if ! mountpoint -q "$CURRENT_MOUNT_PATH"; then
    echo "FAILED: the CIFS share could not be mounted."
    cleanup_current_mount
    failed_count=$((failed_count + 1))
    continue
  fi

  probe_dir="$CURRENT_MOUNT_PATH/.ebs-write-test-$server_index-$$"
  probe_file="$probe_dir/probe.txt"

  if ! mkdir "$probe_dir" || \
     ! printf 'EBS temporary write test\n' > "$probe_file" || \
     ! test -s "$probe_file"; then
    echo "FAILED: mounted successfully, but the write probe failed."
    rm -f "$probe_file" >/dev/null 2>&1 || true
    rmdir "$probe_dir" >/dev/null 2>&1 || true
    cleanup_current_mount
    failed_count=$((failed_count + 1))
    continue
  fi

  if ! rm -f "$probe_file" || ! rmdir "$probe_dir"; then
    echo "FAILED: the probe was written, but its cleanup failed."
    cleanup_current_mount
    failed_count=$((failed_count + 1))
    continue
  fi

  echo "Write and delete probe succeeded. Unmounting with unmount_share.sh..."
  "$UNMOUNT_HELPER" "$CURRENT_MOUNT_PATH" >/dev/null 2>&1 || true

  if mountpoint -q "$CURRENT_MOUNT_PATH"; then
    echo "FAILED: the share remains mounted."
    cleanup_current_mount
    failed_count=$((failed_count + 1))
    continue
  fi

  CURRENT_MOUNT_PATH=""
  echo "PASSED: mount, write, delete, and unmount all succeeded."
  passed_count=$((passed_count + 1))
done < <("$JQ_BIN" -r '.backupServers[] | @base64' "$CONFIG_FILE")

rmdir "$TEST_ROOT" >/dev/null 2>&1 || true

echo
echo "Backup-share validation finished: $passed_count passed, $failed_count failed."

if [ "$failed_count" -ne 0 ]; then
  exit 1
fi

echo "All configured Synology/CIFS backup shares passed validation."
exit 0
