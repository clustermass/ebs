#!/bin/bash
# pass local mounting point (path)
CURR_MOUNT_PATH="$1"
sleep 5

if mountpoint -q "$CURR_MOUNT_PATH"; then
    if ! sudo -n umount "$CURR_MOUNT_PATH"; then
        exit 1
    fi
fi

# A failed mount may leave its empty mount-point directory behind. That is not
# an error and must not be confused with an active CIFS mount on the next run.
if [ -d "$CURR_MOUNT_PATH" ]; then
    rmdir "$CURR_MOUNT_PATH" 2>/dev/null || true
fi

exit 0
