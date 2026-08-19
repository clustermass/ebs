#!/bin/bash
# Discover ESXi SSH fingerprints and, after operator verification, save them in
# the corresponding config.json entries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JQ_BIN="$PROJECT_DIR/bin/jq-linux64"
CONFIG_FILE="${1:-$PROJECT_DIR/config.json}"
BACKUP_FILE=""

fail() {
  echo "Error: $1" >&2
  exit 1
}

[ -x "$JQ_BIN" ] || fail "bundled jq is not executable: $JQ_BIN"
[ -f "$CONFIG_FILE" ] || fail "configuration file not found: $CONFIG_FILE"
command -v ssh-keyscan >/dev/null 2>&1 || fail "ssh-keyscan is missing; install openssh-client"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is missing; install openssh-client"
[ -r /dev/tty ] || fail "an interactive terminal is required to verify host keys"
"$JQ_BIN" empty "$CONFIG_FILE" || fail "configuration is not valid JSON: $CONFIG_FILE"

server_count=$("$JQ_BIN" '.esxiServers | length' "$CONFIG_FILE")
[ "$server_count" -gt 0 ] || fail "no servers were found in .esxiServers"

echo "ESXi SSH host-key setup"
echo "Configuration: $CONFIG_FILE"
echo "Servers found: $server_count"
echo
echo "IMPORTANT: ssh-keyscan does not authenticate a server."
echo "Verify every displayed fingerprint through the ESXi console or another"
echo "trusted channel before accepting it."

updated_count=0
skipped_count=0

while IFS=$'\t' read -r server_name server_host; do
  if [ -z "$server_name" ] || [ -z "$server_host" ]; then
    echo
    echo "Skipping an entry with a missing name or IP address."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  echo
  echo "Server: $server_name ($server_host)"
  echo "Fetching its SSH host key..."

  key_output=$(ssh-keyscan -T 5 -t ed25519,ecdsa,rsa "$server_host" 2>/dev/null || true)

  # ssh-keyscan prints responses in arrival order, which is nondeterministic.
  # Select the key type in the order modern Plink prefers when negotiating with
  # the server so the pinned fingerprint matches the key Plink will receive.
  key_line=$(printf '%s\n' "$key_output" | awk '
    $2 == "ssh-ed25519" && ed25519 == "" { ed25519 = $0 }
    $2 ~ /^ecdsa-sha2-/ && ecdsa == "" { ecdsa = $0 }
    $2 == "ssh-rsa" && rsa == "" { rsa = $0 }
    END {
      if (ed25519 != "") print ed25519
      else if (ecdsa != "") print ecdsa
      else if (rsa != "") print rsa
    }
  ')

  if [ -z "$key_line" ]; then
    echo "No SSH host key was returned. Confirm that SSH is enabled and port 22"
    echo "is reachable, then run this script again."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  fingerprint_line=$(printf '%s\n' "$key_line" | ssh-keygen -lf -)
  fingerprint=$(printf '%s\n' "$fingerprint_line" | awk '{print $2}')
  key_type=$(printf '%s\n' "$fingerprint_line" | awk '{print $NF}' | tr -d '()')

  echo "Key type:    $key_type"
  echo "Fingerprint: $fingerprint"
  # The loop itself reads server records from a process substitution. Read the
  # operator's answer from the terminal so it cannot consume the next record.
  read -r -p "Verified through a trusted source? Type yes to save it: " answer </dev/tty

  if [ "$answer" != "yes" ]; then
    echo "Not saved."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE="$CONFIG_FILE.backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    echo "Configuration backup created: $BACKUP_FILE"
  fi

  config_dir=$(dirname "$CONFIG_FILE")
  temp_file=$(mktemp "$config_dir/.config.json.XXXXXX")
  if ! "$JQ_BIN" --arg name "$server_name" --arg key "$fingerprint" \
    '(.esxiServers[] | select(.name == $name) | .esxiHostKey) = $key' \
    "$CONFIG_FILE" > "$temp_file"; then
    rm -f "$temp_file"
    fail "could not update $server_name"
  fi

  chmod 600 "$temp_file"
  mv "$temp_file" "$CONFIG_FILE"
  echo "Saved for $server_name."
  updated_count=$((updated_count + 1))
done < <("$JQ_BIN" -r '.esxiServers[] | [.name, .ip] | @tsv' "$CONFIG_FILE")

echo
echo "Host-key setup finished: $updated_count updated, $skipped_count skipped."
if [ -n "$BACKUP_FILE" ]; then
  echo "Original configuration backup: $BACKUP_FILE"
fi
