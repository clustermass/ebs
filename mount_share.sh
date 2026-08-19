#!/bin/bash
# pass local mounting point (path), network share, username, password
CURR_MOUNT_PATH="$1"
CURR_SHARE_PATH="$2"
CURR_USER_NAME="$3"
CURR_PASSWORD="$4"

# Capture the identity of the user running EBS before sudo performs the mount.
# The Synology username/password authorize access on the NAS; uid/gid make the
# mounted files locally accessible to the EBS service user.
LOCAL_UID=$(id -u)
LOCAL_GID=$(id -g)

sleep 5

if [ ! -d "$CURR_MOUNT_PATH" ]; then
    mkdir -p "$CURR_MOUNT_PATH" || exit 1
    chmod 700 "$CURR_MOUNT_PATH" || exit 1
fi

if mountpoint -q "$CURR_MOUNT_PATH"; then
    exit 0
fi

timeout 15 sudo -n mount -t cifs \
    -o "username=${CURR_USER_NAME},password=${CURR_PASSWORD},uid=${LOCAL_UID},gid=${LOCAL_GID},forceuid,forcegid" \
    "$CURR_SHARE_PATH" "$CURR_MOUNT_PATH"

exit $?
