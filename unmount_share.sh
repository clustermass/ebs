#!/bin/bash
# pass local mounting point (path)
CURR_MOUNT_PATH="$1"
sleep 5
if ! sudo -n umount "$CURR_MOUNT_PATH"; then
    exit 1
fi
rmdir "$CURR_MOUNT_PATH"
exit $?
