#!/bin/bash
source ./shares_list.cfg

echo $(date -u)  "Mounter script started..." >> $SERVICE_FOLDER/mounter.log
while [ 1 ]
do
	for i in ${!SHARES[@]}; do
		CURR_MOUNT_PATH="$MOUNT_POINT/share_$i"
		CURR_SHARE_PATH=${SHARES[$i]}
		CURR_USER_NAME=${USER_NAMES[$i]}
		CURR_PASSWORD=${PASSWORDS[$i]}
		# Checking & creating mount point directory
		if [ ! -d "$CURR_MOUNT_PATH" ]; then
			echo $(date -u)  "Error: ${CURR_MOUNT_PATH} not found" >> $SERVICE_FOLDER/mounter.log
			echo $(date -u)  "Creating one..." >> $SERVICE_FOLDER/mounter.log
			mkdir -p $CURR_MOUNT_PATH
			chmod 777 $CURR_MOUNT_PATH
		fi
		
		if ! mountpoint -q $CURR_MOUNT_PATH; then
			echo $(date -u)  "Mounting remote share ${CURR_SHARE_PATH}" >> $SERVICE_FOLDER/mounter.log
			sudo mount -t cifs -o username=${CURR_USER_NAME},password="${CURR_PASSWORD}",uid=${USER_ID},gid=${GROUP_ID},forceuid,forcegid, $CURR_SHARE_PATH $CURR_MOUNT_PATH
		fi
	done
 sleep $REFRESH_INTERVAL
done
