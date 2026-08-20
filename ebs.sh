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

RUN_MODE="service"
OUTPUT_MODE="file"
LOCK_FILE="$DIR/process.lock"
LOCK_OWNED=0

usage() {
    cat <<'EOF'
Usage: ./ebs.sh [OPTION]

Without an option, EBS runs continuously and waits for the configured time.

  -n, --run-now  Immediately process every VM currently due for backup, then exit.
  -m, --manual   Select VMs interactively, process them immediately, and stream
                 coordinator and machine output to the terminal.
  -h, --help     Show this help.
EOF
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

case "${1:-}" in
    "") ;;
    -n|--run-now) RUN_MODE="run-now" ;;
    -m|--manual)
        RUN_MODE="manual"
        OUTPUT_MODE="console"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

release_lock() {
    if [ "$LOCK_OWNED" -eq 1 ] && [ -f "$LOCK_FILE" ]; then
        local lock_pid
        read -r lock_pid _ < "$LOCK_FILE" || true
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

acquire_lock() {
    local existing_pid existing_epoch existing_mode

    if [ -f "$LOCK_FILE" ]; then
        read -r existing_pid existing_epoch existing_mode < "$LOCK_FILE" || true
        if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
            echo "Another EBS instance is already running (PID $existing_pid, mode ${existing_mode:-unknown})." >&2
            echo "Stop ebs.service before running EBS manually." >&2
            exit 1
        fi
        echo "Removing stale EBS lock left by PID ${existing_pid:-unknown}." >&2
        rm -f "$LOCK_FILE"
    fi

    if ( set -o noclobber; printf '%s %s %s\n' "$$" "$(date +%s)" "$RUN_MODE" > "$LOCK_FILE" ) 2>/dev/null; then
        LOCK_OWNED=1
        trap release_lock EXIT
        trap 'exit 130' INT
        # systemd uses SIGTERM for a normal requested stop. Exit successfully
        # so the unit becomes inactive instead of entering the failed state;
        # the EXIT trap still releases process.lock.
        trap 'exit 0' TERM
    else
        echo "Another EBS instance acquired $LOCK_FILE. Exiting." >&2
        exit 1
    fi
}

acquire_lock

# Use the jq binary bundled with EBS instead of relying on the system PATH.
jq() {
    "$DIR/bin/jq-linux64" "$@"
}

log() {
    if [ "$OUTPUT_MODE" = "console" ]; then
        printf '%s %s\n' "$(date)" "$1"
    else
        printf '%s %s\n' "$(date)" "$1" >> "$DIR/ebs.log"
    fi
}

MAIN_LOOP_REFRESH_INTERVAL=5
BACKUP_SKIPPED=2
CIFS_MOUNT_ATTEMPTS=5
CIFS_MOUNT_RETRY_INTERVAL=30

MOUNT_SHARE_FOLDER_NAME="backupDestination"

log "ESXi Backup Service script started..."
mkdir -p $DIR/excluded_machines
mkdir -p $DIR/processed_machines
mkdir -p $DIR/mount

for possibleShareMounted in "$DIR/mount"/*; do
    if mountpoint -q "$possibleShareMounted"; then
        sudo -n umount -f "$possibleShareMounted"
    fi
    if [ -d "$possibleShareMounted" ]; then
        rmdir "$possibleShareMounted" 2>/dev/null || true
    fi
done

config=$(<"$DIR/config.json")
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
    log "Backup for $currMachineName started"
    if [ "$OUTPUT_MODE" != "console" ]; then
        rm -f "$DIR/temp_process_machine.log"
    fi
    local currMachineData=$(get_machine_by_name "$currMachineName")
    local currMountPath="$DIR/mount/$MOUNT_SHARE_FOLDER_NAME"
    local backupLog="Starting backup log for machine $currMachineName"
    tempLog() {
        local line="$(date) $1"
        backupLog+="\n$line"
        if [ "$OUTPUT_MODE" = "console" ]; then
            printf '%s\n' "$line"
        fi
    }
    # Checking that no active mount was left by a previous backup. Directory
    # existence alone is not evidence of a mount: failed mount attempts leave
    # an ordinary empty mount-point directory behind.
    if mountpoint -q "$currMountPath"; then
        tempLog "$currMountPath is currently mounted."
        tempLog "Trying to forcefully unmount directory before starting new backup..."
        sudo -n umount -f "$currMountPath" >/dev/null 2>&1 || true
        "$DIR/unmount_share.sh" "$currMountPath"
	fi

    if mountpoint -q "$currMountPath"; then
        tempLog "$currMountPath is still mounted."
        tempLog "Unmount previously mounted directory before starting new backup failed."
        exclude_machine_due_to_error "$currMachineData" "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi

    # Remove an empty directory left by an unsuccessful mount. mount_share.sh
    # will recreate it with the correct permissions.
    if [ -d "$currMountPath" ]; then
        rmdir "$currMountPath" 2>/dev/null || true
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
    
    # sample data: {"name": "DS-218-1-8Tb", "ip": "192.168.1.149", "login": "admin", "password": "Password", "sharePath": "backup1", "mac": "00:11:32:8E:DC:9A", "broadcastIp":"192.168.1.255", "powerOff":"y", "powerOn":"y"},
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
    local mountAttempt
    tempLog "Trying to mount $currSharePath ..."
    for ((mountAttempt = 1; mountAttempt <= CIFS_MOUNT_ATTEMPTS; mountAttempt++)); do
        "$DIR/mount_share.sh" "$currMountPath" "$currSharePath" "$currUserName" "$currPassword"
        if mountpoint -q "$currMountPath"; then
            break
        fi
        if [ "$mountAttempt" -lt "$CIFS_MOUNT_ATTEMPTS" ]; then
            tempLog "CIFS is not ready after mount attempt $mountAttempt/$CIFS_MOUNT_ATTEMPTS; retrying in $CIFS_MOUNT_RETRY_INTERVAL seconds."
            "$DIR/unmount_share.sh" "$currMountPath" >/dev/null 2>&1 || true
            sleep "$CIFS_MOUNT_RETRY_INTERVAL"
        fi
    done

    if ! mountpoint -q "$currMountPath"; then
		tempLog "Shared folder $currSharePath on backup server $backupServerName cannot be mounted. Backup aborted." 
        "$DIR/unmount_share.sh" "$currMountPath" >/dev/null 2>&1 || true
        exclude_machine_due_to_error $(get_machine_by_name "$currMachineName") "$backupLog"
        $DIR/report_error.sh "$currMachineName" "$backupLog"
        return
	fi

    tempLog "$currMountPath seems to be mounted successfully."   
    "$DIR/process_machine.sh" "$currMachineData" "$esxiServerData" "$currMountPath" "$TEMP_BACKUP_STORAGE_PATH" "$DIR" "$OUTPUT_MODE"
    local backupMachineResult=$?
    if [ "$OUTPUT_MODE" != "console" ] && [ -f "$DIR/temp_process_machine.log" ]; then
        backupLog+="\n"
        backupLog+="$(cat "$DIR/temp_process_machine.log")"
        rm "$DIR/temp_process_machine.log"
    fi

    if [ "$backupMachineResult" -ne 0 ]; then
         if [ "$backupMachineResult" -eq "$BACKUP_SKIPPED" ]; then
             log "Backup for $currMachineName was skipped; its last successful-backup timestamp was not changed"
             return
         fi
         tempLog "Backup for $currMachineName failed with exit code $backupMachineResult"
         exclude_machine_due_to_error "$currMachineData" "$backupLog"
         $DIR/report_error.sh "$currMachineName" "$backupLog"
         return
    fi

    # Only mark success if process_machine.sh actually succeeded
    write_machine_success_log "$(get_machine_by_name "$currMachineName")" "$backupLog"
    log "Backup for $currMachineName completed successfully"
}

select_manual_backups() {
    local machine_count=${#machines[@]}
    local selection token index
    local -A selected_indexes=()

    if [ "$machine_count" -eq 0 ]; then
        echo "No VMs are configured."
        return 1
    fi
    if [ ! -t 0 ]; then
        echo "Manual mode requires an interactive terminal." >&2
        return 1
    fi

    printf '\n%-4s %-28s %-18s %-22s %s\n' "#" "VM" "ESXi server" "Backup server" "Period (hours)"
    printf '%-4s %-28s %-18s %-22s %s\n' "----" "----------------------------" "------------------" "----------------------" "--------------"
    for index in "${!machines[@]}"; do
        printf '%-4d %-28s %-18s %-22s %s\n' \
            "$((index + 1))" \
            "$(echo "${machines[$index]}" | jq -r '.name')" \
            "$(echo "${machines[$index]}" | jq -r '.esxiServer')" \
            "$(echo "${machines[$index]}" | jq -r '.backupServer')" \
            "$(echo "${machines[$index]}" | jq -r '.backupPeriod')"
    done

    printf '\nEnter VM numbers separated by commas (or press Enter to cancel): '
    IFS= read -r selection
    if [ -z "${selection//[[:space:]]/}" ]; then
        echo "No VMs selected."
        return 1
    fi

    IFS=',' read -ra requested_indexes <<< "$selection"
    for token in "${requested_indexes[@]}"; do
        token="${token//[[:space:]]/}"
        if ! [[ "$token" =~ ^[0-9]+$ ]] || [ "$token" -lt 1 ] || [ "$token" -gt "$machine_count" ]; then
            echo "Invalid VM number: ${token:-empty}. Nothing was queued." >&2
            pendingBackups=()
            return 1
        fi
        selected_indexes["$token"]=1
    done

    for index in "${!machines[@]}"; do
        if [ "${selected_indexes[$((index + 1))]:-0}" -eq 1 ]; then
            pendingBackups+=("$(get_machine_name "${machines[$index]}")")
        fi
    done
}

process_pending_backups() {
    local pendingBackupsLength=${#pendingBackups[@]}
    if [ "$pendingBackupsLength" -eq 0 ]; then
        return
    fi

    log "$pendingBackupsLength machines were added for backups."
    while [ "$pendingBackupsLength" -ne 0 ]; do
        local currentMachineName="${pendingBackups[0]}"
        remove_machine_from_pending_backups_array_by_idx 0
        pendingBackupsLength=${#pendingBackups[@]}
        process_machine_backup_by_name "$currentMachineName"
        sleep 10
        "$DIR/unmount_share.sh" "$DIR/mount/$MOUNT_SHARE_FOLDER_NAME"
    done
    log "All machines added for a backup have been processed."
    power_off_all_flagged_backup_servers
}

if [ "$RUN_MODE" = "run-now" ]; then
    log "Immediate backup check was requested."
    add_due_for_backup_machines_to_pending_backups_array
    if [ "${#pendingBackups[@]}" -eq 0 ]; then
        log "No machines are currently due for backup."
        exit 0
    fi
    process_pending_backups
    exit 0
fi

if [ "$RUN_MODE" = "manual" ]; then
    log "Interactive manual backup was requested."
    select_manual_backups || exit 0
    process_pending_backups
    exit 0
fi

lastScheduleTrigger=""
while [ 1 ]; do
    timeNow=$(get_current_military_time)
    pendingBackupsLength=${#pendingBackups[@]}
    scheduleTrigger="$(date +'%Y%m%d%H%M')"
    if [ "$timeNow" == "$prefferedBackupStartTime" ] && \
       [ "$pendingBackupsLength" == 0 ] && \
       [ "$scheduleTrigger" != "$lastScheduleTrigger" ]; then
        lastScheduleTrigger="$scheduleTrigger"
        log "Backup was triggered according to the preffered backup start time $prefferedBackupStartTime"
        add_due_for_backup_machines_to_pending_backups_array
    fi
    process_pending_backups
    sleep "$MAIN_LOOP_REFRESH_INTERVAL"
done
