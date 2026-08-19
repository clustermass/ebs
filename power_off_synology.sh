#!/bin/bash
# pass Synology username, password and ip address
# COMMAND_TIMEOUT=120 # 120 Seconds timeout if ssh connection hangs up
# timeout $COMMAND_TIMEOUT sshpass -p "$2" ssh "$1@$3" "echo \"$2\" | sudo -S /bin/bash; sudo poweroff;"
# exit $?

COMMAND_TIMEOUT=120 # seconds

USERNAME="$1"
PASSWORD="$2"
HOST_IP="$3"

# Helper: check if NAS is reachable
is_nas_alive() {
  ping -c 1 -W 3 "$HOST_IP" >/dev/null 2>&1
  return $?
}

# Send shutdown over SSH non-interactively
timeout "$COMMAND_TIMEOUT" \
  sshpass -p "$PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$USERNAME@$HOST_IP" \
    "echo '$PASSWORD' | sudo -S poweroff"

rc=$?

# Case 1: SSH returned 0 → we’re happy.
if [ "$rc" -eq 0 ]; then
  exit 0
fi

# Case 2: Non-zero (255, 124, whatever). Could be:
#   - SSH killed by host shutting down (normal for poweroff)
#   - Timeout
#   - Real auth/network error
#
# Let's probe the host: if it is no longer reachable, consider
# the shutdown successful. Otherwise, propagate the error.

# give the NAS a moment to actually go down
sleep 10

if is_nas_alive; then
  # still reachable → real failure
  exit "$rc"
else
  # host is gone from the network → treat as success
  exit 0
fi
