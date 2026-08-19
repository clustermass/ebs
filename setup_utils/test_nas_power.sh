#!/bin/bash
# Power-cycle each unique physical NAS configured in backupServers.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JQ_BIN="$PROJECT_DIR/bin/jq-linux64"
POWER_OFF_HELPER="$PROJECT_DIR/power_off_synology.sh"
POWER_ON_HELPER="$PROJECT_DIR/power_on_synology.sh"
CONFIG_FILE="${1:-$PROJECT_DIR/config.json}"

SHUTDOWN_TIMEOUT=180
STARTUP_TIMEOUT=300
POLL_INTERVAL=2
POWER_OFF_SETTLE_TIME=30

RECOVERY_NEEDED=0
RECOVERY_NAME=""
RECOVERY_IP=""
RECOVERY_MAC=""
RECOVERY_BROADCAST=""

fail() {
  echo "Error: $1" >&2
  exit 1
}

is_online() {
  ping -c 1 -W 1 "$1" >/dev/null 2>&1
}

wait_for_state() {
  local ip_address="$1"
  local desired_state="$2"
  local timeout_seconds="$3"
  local elapsed=0
  local consecutive_offline_checks=0

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if [ "$desired_state" = "online" ] && is_online "$ip_address"; then
      return 0
    fi
    if [ "$desired_state" = "offline" ]; then
      if is_online "$ip_address"; then
        consecutive_offline_checks=0
      else
        consecutive_offline_checks=$((consecutive_offline_checks + 1))
        if [ "$consecutive_offline_checks" -ge 3 ]; then
          return 0
        fi
      fi
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  return 1
}

attempt_recovery() {
  if [ "$RECOVERY_NEEDED" -ne 1 ]; then
    return
  fi

  echo
  echo "Recovery: sending Wake-on-LAN to $RECOVERY_NAME ($RECOVERY_IP)..." >&2
  "$POWER_ON_HELPER" "$RECOVERY_MAC" "$RECOVERY_BROADCAST" \
    "$RECOVERY_IP" --send-only </dev/null >/dev/null 2>&1 || true
  RECOVERY_NEEDED=0
}

trap attempt_recovery EXIT
trap 'attempt_recovery; exit 130' INT TERM

[ -x "$JQ_BIN" ] || fail "bundled jq is not executable: $JQ_BIN"
[ -x "$POWER_OFF_HELPER" ] || fail "power-off helper is not executable: $POWER_OFF_HELPER"
[ -x "$POWER_ON_HELPER" ] || fail "power-on helper is not executable: $POWER_ON_HELPER"
[ -f "$CONFIG_FILE" ] || fail "configuration file not found: $CONFIG_FILE"
command -v ping >/dev/null 2>&1 || fail "ping is missing; install iputils-ping"
command -v wakeonlan >/dev/null 2>&1 || fail "wakeonlan is missing"
[ -r /dev/tty ] || fail "an interactive terminal is required for confirmation"
"$JQ_BIN" empty "$CONFIG_FILE" || fail "configuration is not valid JSON: $CONFIG_FILE"

entry_count=$("$JQ_BIN" '.backupServers | length' "$CONFIG_FILE")
[ "$entry_count" -gt 0 ] || fail "no servers were found in .backupServers"

echo "DESTRUCTIVE NAS power-cycle validation"
echo "Configuration: $CONFIG_FILE"
echo "Backup-server entries found: $entry_count"
echo
echo "Each tested NAS will be shut down and restarted. Stop all NAS activity,"
echo "unmount its shares on other clients, and confirm that Synology Wake-on-LAN"
echo "is enabled before approving a test."

declare -A processed_ips
passed_count=0
failed_count=0
skipped_count=0
entry_index=0

while IFS= read -r encoded_server; do
  entry_index=$((entry_index + 1))
  server_json=$(printf '%s' "$encoded_server" | base64 --decode)
  server_name=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.name // empty')
  server_ip=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.ip // empty')
  server_login=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.login // empty')
  server_password=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.password // empty')
  server_mac=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.mac // empty')
  server_broadcast=$(printf '%s' "$server_json" | "$JQ_BIN" -r '.broadcastIp // empty')

  echo
  echo "[$entry_index/$entry_count] NAS: ${server_name:-unnamed} (${server_ip:-no IP})"

  if [ -z "$server_name" ] || [ -z "$server_ip" ] || \
     [ -z "$server_login" ] || [ -z "$server_password" ] || \
     [ -z "$server_mac" ] || [ -z "$server_broadcast" ]; then
    echo "FAILED: name, ip, login, password, mac, and broadcastIp are required."
    failed_count=$((failed_count + 1))
    continue
  fi

  if [ -n "${processed_ips[$server_ip]:-}" ]; then
    echo "SKIPPED: this physical NAS IP was already tested through another share."
    skipped_count=$((skipped_count + 1))
    continue
  fi
  processed_ips["$server_ip"]=1

  if ! is_online "$server_ip"; then
    echo "FAILED: NAS is offline. It must be online before this test starts."
    failed_count=$((failed_count + 1))
    continue
  fi

  read -r -p "Type power-cycle to shut down and restart this NAS: " answer </dev/tty
  if [ "$answer" != "power-cycle" ]; then
    echo "SKIPPED: operator did not approve the power cycle."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  echo "Sending the Synology shutdown command..."
  RECOVERY_NEEDED=1
  RECOVERY_NAME="$server_name"
  RECOVERY_IP="$server_ip"
  RECOVERY_MAC="$server_mac"
  RECOVERY_BROADCAST="$server_broadcast"

  "$POWER_OFF_HELPER" "$server_login" "$server_password" \
    "$server_ip" </dev/null >/dev/null 2>&1 || true

  echo "Waiting up to $SHUTDOWN_TIMEOUT seconds for the NAS to go offline..."
  if ! wait_for_state "$server_ip" offline "$SHUTDOWN_TIMEOUT"; then
    echo "FAILED: NAS did not go offline within $SHUTDOWN_TIMEOUT seconds."
    RECOVERY_NEEDED=0
    failed_count=$((failed_count + 1))
    continue
  fi

  echo "NAS is offline. Waiting $POWER_OFF_SETTLE_TIME seconds before Wake-on-LAN..."
  sleep "$POWER_OFF_SETTLE_TIME"

  echo "Sending Wake-on-LAN..."
  "$POWER_ON_HELPER" "$server_mac" "$server_broadcast" \
    "$server_ip" --send-only </dev/null >/dev/null 2>&1 || true

  echo "Waiting up to $STARTUP_TIMEOUT seconds for the NAS to answer ping..."
  if ! wait_for_state "$server_ip" online "$STARTUP_TIMEOUT"; then
    echo "FAILED: NAS did not return online within $STARTUP_TIMEOUT seconds."
    echo "Sending one final recovery Wake-on-LAN packet."
    attempt_recovery
    failed_count=$((failed_count + 1))
    continue
  fi

  RECOVERY_NEEDED=0
  echo "PASSED: NAS shut down and returned online successfully."
  passed_count=$((passed_count + 1))
done < <("$JQ_BIN" -r '.backupServers[] | @base64' "$CONFIG_FILE")

echo
echo "NAS power validation finished: $passed_count passed, $failed_count failed, $skipped_count skipped."

if [ "$failed_count" -ne 0 ]; then
  exit 1
fi

echo "All approved physical NAS devices passed power-cycle validation."
exit 0
