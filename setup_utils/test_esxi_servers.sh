#!/bin/bash
# Perform a read-only connection test against every configured ESXi server.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JQ_BIN="$PROJECT_DIR/bin/jq-linux64"
CONFIG_FILE="${1:-$PROJECT_DIR/config.json}"

fail() {
  echo "Error: $1" >&2
  exit 1
}

[ -x "$JQ_BIN" ] || fail "bundled jq is not executable: $JQ_BIN"
[ -f "$CONFIG_FILE" ] || fail "configuration file not found: $CONFIG_FILE"
command -v plink >/dev/null 2>&1 || fail "plink is missing; install putty-tools"
command -v timeout >/dev/null 2>&1 || fail "timeout is missing; install coreutils"
"$JQ_BIN" empty "$CONFIG_FILE" || fail "configuration is not valid JSON: $CONFIG_FILE"

server_count=$("$JQ_BIN" '.esxiServers | length' "$CONFIG_FILE")
[ "$server_count" -gt 0 ] || fail "no servers were found in .esxiServers"

echo "Read-only ESXi connection validation"
echo "Configuration: $CONFIG_FILE"
echo "Servers found: $server_count"

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
  server_host_key=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.esxiHostKey // empty')

  echo
  echo "[$server_index/$server_count] Testing: ${server_name:-unnamed ESXi server} (${server_ip:-no IP})"

  if [ -z "$server_name" ] || [ -z "$server_ip" ] || \
     [ -z "$server_login" ] || [ -z "$server_password" ] || \
     [ -z "$server_host_key" ]; then
    echo "FAILED: name, ip, login, password, and esxiHostKey are all required."
    failed_count=$((failed_count + 1))
    continue
  fi

  command_output=$(timeout 30 plink -ssh -batch \
    -hostkey "$server_host_key" \
    -pw "$server_password" \
    "$server_login@$server_ip" \
    "vim-cmd vmsvc/getallvms" </dev/null 2>&1)
  command_result=$?

  if [ "$command_result" -ne 0 ]; then
    echo "FAILED: SSH or vim-cmd returned exit code $command_result."
    printf '%s\n' "$command_output" | tail -n 3 | sed 's/^/  /'
    if printf '%s\n' "$command_output" | grep -q \
      'Host key not in manually configured list'; then
      echo "  Re-run setup_utils/update_esxi_host_keys.sh and verify the newly"
      echo "  selected fingerprint through a trusted source."
    fi
    failed_count=$((failed_count + 1))
    continue
  fi

  vm_count=$(printf '%s\n' "$command_output" | \
    awk '$1 ~ /^[0-9]+$/ {count++} END {print count+0}')
  echo "PASSED: pinned-key SSH connection and read-only vim-cmd succeeded."
  echo "Registered VMs reported: $vm_count"
  passed_count=$((passed_count + 1))
done < <("$JQ_BIN" -r '.esxiServers[] | @base64' "$CONFIG_FILE")

echo
echo "ESXi validation finished: $passed_count passed, $failed_count failed."

if [ "$failed_count" -ne 0 ]; then
  exit 1
fi

echo "All configured ESXi servers passed validation."
exit 0
