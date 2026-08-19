#!/bin/bash

#https://kb.vmware.com/s/article/1003757
#Notes: 
#Avoid spaces, brackets, or non UTF-8 characters when naming virtual machines and their associated files. 
#Avoid naming VMs using names where one can be a substring of another, i.e.: Test-VM, Test-VM2. grep may accidentally pick Test-VM2 as a match for Test-VM
# Dependencies: putty-tools, sshpass, ssh, wakeonlan
#Set backupPeriod for machines in hours

SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# Use the jq binary bundled with EBS instead of relying on the system PATH.
jq() {
    "$DIR/bin/jq-linux64" "$@"
}

log() {
    echo $(date)  "$1" >> $DIR/ebs.log
}

MAIN_LOOP_REFRESH_INTERVAL=5

MOUNT_SHARE_FOLDER_NAME="backupDestination"

log "ESXi Backup Service script started..."
mkdir -p $DIR/excluded_machines
mkdir -p $DIR/processed_machines
mkdir -p $DIR/mount

 for possibleShareMounted in "$DIR/mount"/*
    do 
       if [ -d "$possibleShareMounted" ]; then
                sudo -n umount -f "$possibleShareMounted"
                rmdir "$possibleShareMounted"
       fi
    done

config=$(<config.json)
machines=()
esxiServers=()
backupServers=()
pendingBackups=()
pendingPowerOffServerNames=()

TEMP_BACKUP_STORAGE_PATH=$(echo $config | jq -c ".commonConfig.tempBackupStoragePath")
TEMP_BACKUP_STORAGE_PATH="${TEMP_BACKUP_STORAGE_PATH%\"}"
TEMP_BACKUP_STORAGE_PATH="${TEMP_BACKUP_STORAGE_PATH#\"}"

stringPrefferedBackupStartTime=$(echo $config | jq -c ".commonConfig.prefferedBackupStartTime")
stringPrefferedBackupStartTime=$(echo $stringPrefferedBackupStartTime | sed -e 's/\://g')
stringPrefferedBackupStartTime="${stringPrefferedBackupStartTime%\"}"
stringPrefferedBackupStartTime="${stringPrefferedBackupStartTime#\"}"
prefferedBackupStartTime=300
printf -v prefferedBackupStartTime $stringPrefferedBackupStartTime 2>/dev/null
# echo $prefferedBackupStartTime
log "preffered backup start time is set to $prefferedBackupStartTime"


get_machine_name () {
   echo $(echo $1 | jq -r ".name")
}

# Initialization


readarray -t allMachines < <(echo $config | jq -c ".machines[]")
for machine in "${allMachines[@]}"; do
    machines+=("${machine//[$'\t\r\n ']}")
    log "machine $(get_machine_name $machine) added."
    log "machine config $machine"
done

readarray -t allEsxiServers < <(echo $config | jq -c ".esxiServers[]")
for esxiServer in "${allEsxiServers[@]}"; do
    esxiServers+=("$esxiServer")
done

readarray -t allBackupServers < <(echo $config | jq -c ".backupServers[]")
for backupServer in "${allBackupServers[@]}"; do
    backupServers+=("$backupServer")
done

# Initialization finished

# Common methods start
is_machine_available () {
  ping "$1" -w 3 -c 2 >> /dev/null
  local result=$?
    if [ $result == 0 ]; then
    	echo 1    
    else
    	echo 0
	fi
}

add_server_name_for_powering_off () {
   local serverName="$1"
   local addThisServerName=1
    for i in ${!pendingPowerOffServerNames[@]}; do
        local server_name=${pendingPowerOffServerNames[$i]}
        if [ "$server_name" = "$serverName" ]; then
        # if the server name is already in the 
        #pendingPowerOffServerNames, we won't add it again
        addThisServerName=0
        break
        fi
    done
    if [ $addThisServerName == 1 ]; then
        pendingPowerOffServerNames[${#pendingPowerOffServerNames[@]}]="$serverName"
	fi
}
# Common methods end
# esxi server manipulation methods start

get_esxi_server_name () {
   echo $(echo $1 | jq -r ".name")
}

get_esxi_server_data_by_name () {
    for i in ${!esxiServers[@]}; do
        local esxi_server_data=${esxiServers[$i]}
        local esxi_server_name=$(get_esxi_server_name "$esxi_server_data")
        if [ "$esxi_server_name" = "$1" ]; then
        echo $esxi_server_data
        break
        fi
    done
}
# esxi server manipulation methods end

# backup server manipulation methods start
get_backup_server_name () {
   echo $(echo $1 | jq -r ".name")
}

get_backup_server_data_by_name () {
    for i in ${!backupServers[@]}; do
        local backup_server_data=${backupServers[$i]}
        local backup_server_name=$(get_backup_server_name "$backup_server_data")
        if [ "$backup_server_name" = "$1" ]; then
        echo $backup_server_data
        break
        fi
    done
}

power_off_all_flagged_backup_servers () {
    if [ ${#pendingPowerOffServerNames[@]} -eq 0 ]; then
        log "No backup servers flagged for power off."
        return
    fi

    log "Powering off all flagged backup servers..."

    # Track which physical NAS IPs we've already processed
    declare -A processedIps

    for i in "${!pendingPowerOffServerNames[@]}"; do
        local backupServerName=${pendingPowerOffServerNames[$i]}
        local backupServerData
        backupServerData=$(get_backup_server_data_by_name "$backupServerName")

        local backupServerIp currUserName currPassword
        backupServerIp=$(echo "$backupServerData" | jq -r ".ip")
        currUserName=$(echo "$backupServerData" | jq -r ".login")
        currPassword=$(echo "$backupServerData" | jq -r ".password")

        if [ -z "$backupServerIp" ] || [ -z "$currUserName" ] || [ -z "$currPassword" ]; then
            log "Skipping power off for '$backupServerName' – missing IP/credentials"
            continue
        fi

        # If we've already processed this IP (another share on same NAS),
        # don't try to shut it down again.
        if [[ -n "${processedIps[$backupServerIp]}" ]]; then
            log "Skipping power off for '$backupServerName' – NAS $backupServerIp already processed"
            continue
        fi

        processedIps["$backupServerIp"]=1

        # Check if NAS is reachable before sending poweroff
        local isNasAlive
        isNasAlive=$(is_machine_available "$backupServerIp")

        if [ "$isNasAlive" != 1 ]; then
            log "NAS '$backupServerName' at $backupServerIp is unreachable (likely already powered off). Skipping shutdown."
            continue
        fi

        log "Sending shutdown command to NAS '$backupServerName' at $backupServerIp"
        "$DIR/power_off_synology.sh" "$currUserName" "$currPassword" "$backupServerIp"
        local rc=$?

        if [ "$rc" -ne 0 ]; then
            log "power_off_synology.sh for '$backupServerName' ($backupServerIp) failed with code $rc"
        else
            log "Shutdown command for '$backupServerName' ($backupServerIp) completed successfully"
        fi

        # Avoid hammering multiple NASes at the same instant
        sleep 10
    done

    # Clear the queue now that we've attempted all shutdowns
    pendingPowerOffServerNames=()
}
# backup server manipulation methods end


get_current_military_time () {
    local localTimeNow
    stringlocalTimeNow=$(echo $(date +'%R') | sed -e 's/\://g')
    printf -v localTimeNow $stringlocalTimeNow 2>/dev/null
    echo $localTimeNow
}

get_machine_name () {
   echo $(echo $1 | jq -r ".name")
}

get_machine_backup_period () {
    local hours=$(echo $1 | jq -r ".backupPeriod")
    echo $(($hours * 60 * 60))
}

get_machine_by_name () {
    for i in ${!machines[@]}; do
        local machine_data=${machines[$i]}
        local machine_name=$(get_machine_name "$machine_data")
        if [ "$machine_name" = "$1" ]; then
        echo $machine_data
        break
        fi
    done
}
# (machine data, error log)
exclude_machine_due_to_error () {
    # echo $(date) >> "$DIR/excluded_machines/$(get_machine_name "$1").err"
    # echo "---------- LOG STARTS ----------" >> "$DIR/excluded_machines/$(get_machine_name "$1").err"
    # echo -e "$2" >>  "$DIR/excluded_machines/$(get_machine_name "$1").err"
    # echo "---------- LOG ENDS ----------" >> "$DIR/excluded_machines/$(get_machine_name "$1").err"
     local machineName
    machineName=$(get_machine_name "$1")
    local errFile="$DIR/excluded_machines/$machineName.err"

    if ! test -f "$errFile"; then
        printf '\n' >> "$errFile"
    fi
    echo "---------- LOG ENDS ----------" \
      | cat - "$errFile" > temp && mv temp "$errFile"

    printf '%b\n' "$2" \
      | cat - "$errFile" > temp && mv temp "$errFile"

    echo "---------- LOG STARTS ----------" \
      | cat - "$errFile" > temp && mv temp "$errFile"

    date \
      | cat - "$errFile" > temp && mv temp "$errFile"

    date +%s \
      | cat - "$errFile" > temp && mv temp "$errFile"
}

# (machine, log)
write_machine_success_log () {
    # if ! test -f "$DIR/processed_machines/$(get_machine_name "$1").log"; then
    #     echo -e "\n" >> "$DIR/processed_machines/$(get_machine_name "$1").log"
    # fi
    # echo "---------- LOG ENDS ----------" | cat - "$DIR/processed_machines/$(get_machine_name "$1").log" > temp && mv temp "$DIR/processed_machines/$(get_machine_name "$1").log"
    # echo -e $2 | cat - "$DIR/processed_machines/$(get_machine_name "$1").log" > temp && mv temp "$DIR/processed_machines/$(get_machine_name "$1").log"
    # echo "---------- LOG STARTS ----------" | cat - "$DIR/processed_machines/$(get_machine_name "$1").log" > temp && mv temp "$DIR/processed_machines/$(get_machine_name "$1").log"
    # echo $(date) | cat - "$DIR/processed_machines/$(get_machine_name "$1").log" > temp && mv temp "$DIR/processed_machines/$(get_machine_name "$1").log"
    # echo $(date +%s) | cat - "$DIR/processed_machines/$(get_machine_name "$1").log" > temp && mv temp "$DIR/processed_machines/$(get_machine_name "$1").log"
     local machineName
    machineName=$(get_machine_name "$1")
    local logFile="$DIR/processed_machines/$machineName.log"

    # Ensure file exists (optional)
    if ! test -f "$logFile"; then
        printf '\n' >> "$logFile"
    fi
    echo "---------- LOG ENDS ----------" \
      | cat - "$logFile" > temp && mv temp "$logFile"

    #Prepend backup log content (preserving all newlines)
    printf '%b\n' "$2" \
      | cat - "$logFile" > temp && mv temp "$logFile"

    #Prepend "LOG STARTS"
    echo "---------- LOG STARTS ----------" \
      | cat - "$logFile" > temp && mv temp "$logFile"

    #Prepend human-readable date
    date \
      | cat - "$logFile" > temp && mv temp "$logFile"

    #Prepend epoch timestamp
    date +%s \
      | cat - "$logFile" > temp && mv temp "$logFile"
}

check_if_machine_is_excluded_from_backup_by_name () {
    machineIsExcluded=0
    shopt -s nullglob
    for excludedMachineName in "$DIR/excluded_machines"/*
    do
        local machineName=$(echo $excludedMachineName | rev | cut -d '/' -f 1 | cut -d '.' -f 2- | rev)
        if [ "$machineName" == "$1" ]; then
            machineIsExcluded=1
            break 
        fi
    done
    shopt -u nullglob
    echo $machineIsExcluded
}

get_machine_last_backup_timestamp_by_name () {
    local lastBackupTimestamp=0
    for lastBackupLogFile in "$DIR/processed_machines"/*
    do
        local machineName=$(echo "$lastBackupLogFile" | rev | cut -d '/' -f 1 | cut -d '.' -f 2- | rev)
        if [ "$machineName" == "$1" ]; then
            lastBackupTimestamp=$(head -n 1 "$lastBackupLogFile")
            break 
        fi
    done
    echo "$lastBackupTimestamp"
}

check_if_machine_is_due_for_backup () {
    local dueForBackup=0
    local machine="$1"
    local machineName=$(get_machine_name "$machine")
    local excluded=$(check_if_machine_is_excluded_from_backup_by_name "$machineName")
    if [ $excluded != 1 ]; then
        local lastBackupInEpoch=$(get_machine_last_backup_timestamp_by_name "$machineName")
        if [ $lastBackupInEpoch == 0 ]; then
         # if lastBackupInEpoch == 0 then previous log file doesn't exist.
         dueForBackup=1
         echo "$dueForBackup"
         return
        else
         local backupPeriodInSeconds=$(get_machine_backup_period "$machine") 
         local nowInEpoch=$(date +%s)
         local supposedNextBackupInEpoch=$(($lastBackupInEpoch + $backupPeriodInSeconds))
          if (($nowInEpoch >= $supposedNextBackupInEpoch)); then
            dueForBackup=1
            echo "$dueForBackup"
            return
          else
            echo "$dueForBackup"
            return
          fi
        fi
    fi
    echo $dueForBackup
}

add_due_for_backup_machines_to_pending_backups_array () {
    for i in ${!machines[@]}; do
        local isMachineDueForBackup=$(check_if_machine_is_due_for_backup "${machines[$i]}")
        if [ $isMachineDueForBackup == 1 ]; then
            pendingBackups[${#pendingBackups[@]}]=$(get_machine_name "${machines[$i]}")
        fi
    done
}

remove_machine_from_pending_backups_array_by_idx () {
    local indexToRemove=$1
    local tempArray=()
    for i in ${!pendingBackups[@]}; do
        if [ $i != $indexToRemove ]; then
            tempArray+=("${pendingBackups[$i]}")
        fi
    done
    pendingBackups=("${tempArray[@]}")
}

process_machine_backup_by_name () {
    local currMachineName="$1"
    log "Backup for "$currMachineName" started"
    rm -f "$DIR/temp_process_machine.log"
    local currMachineName="$1"
    local currMachineData=$(get_machine_by_name "$currMachineName")
    local currMountPath="$DIR/mount/$MOUNT_SHARE_FOLDER_NAME"
    local backupLog="Starting backup log for machine $currMachineName"
    tempLog() {
         	backupLog+="\n"
            backupLog+="$(date) $1"
    }
    # Checking that no mounted folder was left by previous backup
    if [ -d "$currMountPath" ]; then
        tempLog "$currMountPath is currently mounted."
        tempLog "Trying to forcefully unmount directory before starting new backup..."
        sleep 3
        sudo -n umount -f "$currMountPath"
        $DIR/unmount_share.sh "$currMountPath"
        sleep 3
	fi

    if [ -d "$currMountPath" ]; then
        tempLog "$currMountPath is still mounted."
        tempLog "Unmount previously mounted directory before starting new backup failed."
        exclude_machine_due_to_error "$currMachineData" "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi

    # Pulling esxi server name for this machine.
    local esxiServerName=$(echo "$currMachineData" | jq -r ".esxiServer")
    tempLog "$esxiServerName esxi server will be used for this machine."
    # Pulling esxi server credentials for this machine.
    local esxiServerData=$(get_esxi_server_data_by_name "$esxiServerName")
    local esxiIpAddress=$(echo $esxiServerData | jq -r ".ip")
    # Checking if esxi server is alive.
    local isEsxiServerAlive=$(is_machine_available "$esxiIpAddress")
    if [ "$isEsxiServerAlive" != 1 ]; then
    	tempLog "esxi server $esxiServerName is not available at the $esxiIpAddress IP address. Backup aborted." 
        exclude_machine_due_to_error "$currMachineData" "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi
    tempLog "esxi server $esxiServerName is available at the $esxiIpAddress IP address. Continuing..." 
    # Pulling backup server name for this machine.
    local backupServerName=$(echo "$currMachineData" | jq -r ".backupServer")
    tempLog "$backupServerName backup server will be used for this machine."
    # Pulling backup server credentials & aux data for this machine.
    local backupServerData=$(get_backup_server_data_by_name "$backupServerName")
    
    local backupServerIp=$(echo $backupServerData | jq -r ".ip")
    local backupServerSharePath=$(echo $backupServerData | jq -r ".sharePath")
    local currSharePath="//$backupServerIp/$backupServerSharePath"
    local currUserName=$(echo $backupServerData | jq -r ".login")
    local currPassword=$(echo $backupServerData | jq -r ".password")
    local backupServerMac=$(echo $backupServerData | jq -r ".mac")
    local backupServerBroadcastIp=$(echo $backupServerData | jq -r ".broadcastIp")
    local backupServerPowerOff=$(echo $backupServerData | jq -r ".powerOff")
    local backupServerPowerOn=$(echo $backupServerData | jq -r ".powerOn")

    if [ "$backupServerPowerOn" == "y" ] && [ "$backupServerMac" != "" ] && [ "$backupServerBroadcastIp" != "" ] && [ "$backupServerIp" != "" ]; then
        tempLog "Backup server $backupServerName for this machine is configured to be powered on via WOL."    
        if [ "$backupServerPowerOff" == "y" ] && [ "$backupServerIp" != "" ] && [ "$currUserName" != "" ] && [ "$currPassword" != "" ]; then
            tempLog "Backup server $backupServerName for this machine is configured to be powered off after task is finished."       
            add_server_name_for_powering_off "$backupServerName"
        fi
        # Trying to power on the backup server
        # passing Synology mac address, broadcast address and target machine ip address
        tempLog "Trying to power up server $backupServerName via WOL if it is not already running."   
        $DIR/power_on_synology.sh "$backupServerMac" "$backupServerBroadcastIp" "$backupServerIp"
    fi

    local isBackupServerAlive=$(is_machine_available "$backupServerIp")
    
    if [ "$isBackupServerAlive" != 1 ]; then
    	tempLog "backup server $backupServerName is not available at the $backupServerIp IP address. Backup aborted." 
        exclude_machine_due_to_error "$currMachineData" "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi

    tempLog "$backupServerName seems to be alive."   
   
    # Trying to power on the backup server
    # passing local mounting point (path), network share, username, password
    tempLog "Trying to mount $currSharePath ..." 
    $DIR/mount_share.sh "$currMountPath" "$currSharePath" "$currUserName" "$currPassword"

    if ! mountpoint -q "$currMountPath"; then
		tempLog "Shared folder $currSharePath on backup server $backupServerName cannot be mounted. Backup aborted." 
        exclude_machine_due_to_error $(get_machine_by_name "$currMachineName") "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi

    tempLog "$currMountPath seems to be mounted successfully."   
    $DIR/process_machine.sh "$currMachineData" "$esxiServerData" "$currMountPath" "$TEMP_BACKUP_STORAGE_PATH" "$DIR"
    local backupMachineResult=$?
    if [ -f "$DIR/temp_process_machine.log" ]; then
        backupLog+="\n"
        backupLog+="$(cat "$DIR/temp_process_machine.log")"
        rm "$DIR/temp_process_machine.log"
    fi

    if [ "$backupMachineResult" -ne 0 ]; then
         tempLog "Backup for $currMachineName failed with exit code $backupMachineResult"
         exclude_machine_due_to_error "$currMachineData" "$backupLog"
         $DIR/report_error.sh "$currMachineName" "$backupLog"
         return
    fi

    # Only mark success if process_machine.sh actually succeeded
    write_machine_success_log "$(get_machine_by_name "$currMachineName")" "$backupLog"
    log "Backup for $currMachineName completed successfully"
}
    
    while [ 1 ]
    do
       timeNow=$(get_current_military_time)
       pendingBackupsLength=${#pendingBackups[@]}
       if [ "$timeNow" == "$prefferedBackupStartTime" ] && [ "$pendingBackupsLength" == 0 ]; then
            log "Backup was triggered according to the preffered backup start time $prefferedBackupStartTime"
            add_due_for_backup_machines_to_pending_backups_array
       fi
       # proceed with backups if any machines were added
       pendingBackupsLength=${#pendingBackups[@]}
       if [ "$pendingBackupsLength" != 0 ]; then
            log "$pendingBackupsLength machines were added for backups."
          
             while [ $pendingBackupsLength != 0 ]
             do
                currentMachineName="${pendingBackups[0]}"
                remove_machine_from_pending_backups_array_by_idx 0
                pendingBackupsLength=${#pendingBackups[@]}
                process_machine_backup_by_name "$currentMachineName"
                sleep 10
                #Unmounting possibly mounted directory for backup destiantion
                CURR_MOUNT_PATH="$DIR/mount/$MOUNT_SHARE_FOLDER_NAME"
                $DIR/unmount_share.sh "$CURR_MOUNT_PATH"
             done
            log "All machines added for a backup has been processed."
            power_off_all_flagged_backup_servers
       fi
    sleep $MAIN_LOOP_REFRESH_INTERVAL
    done
