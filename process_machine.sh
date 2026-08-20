#!/bin/bash
# pass machine data, esxi server data, current mounted path for machine backup, temporary backup storage path, script current directory

CURR_MACHINE_DATA="$1"
ESXI_SERVER_DATA="$2"
CURRENT_MOUNT_PATH="$3"
TEMP_BACKUP_STORAGE_PATH="$4"
DIR="$5"
OUTPUT_MODE="${6:-file}"

# Resolve bundled tools from the EBS installation directory supplied by ebs.sh.
JQ_BIN="$DIR/bin/jq-linux64"
OVFTOOL_BIN="$DIR/bin/ovftool/ovftool"

jq() {
  "$JQ_BIN" "$@"
}

# config=$(<test_config.json)
# CURR_MACHINE_DATA=$(echo $config | jq -c ".machine")
# ESXI_SERVER_DATA=$(echo $config | jq -c ".esxiServer")
# CURRENT_MOUNT_PATH="/home/mm/Documents/ebs/mount/backupDestination"
# TEMP_BACKUP_STORAGE_PATH="/home/mm/backup"
# DIR="/home/mm/Documents/ebs"

# possiblePowerStates:
POWERED_OFF="Powered off"
POWERED_ON="Powered on"
SUSPENDED="Suspended"
BACKUP_SKIPPED=2


# --- ESXi connection details ---
esxiIpAddress=$(echo "$ESXI_SERVER_DATA" | jq -r ".ip")
esxiLogin=$(echo "$ESXI_SERVER_DATA" | jq -r ".login")
esxiPassword=$(echo "$ESXI_SERVER_DATA" | jq -r ".password")
dataStoreName=$(echo "$CURR_MACHINE_DATA" | jq -r ".dataStoreName")
esxiHostKey=$(echo "$ESXI_SERVER_DATA" | jq -r ".esxiHostKey")


machineId=""
currentMachinePowerState=""
initialMachinePowerState=""
powerRestoreAttempted=0

tempLog() {
  if [ "$OUTPUT_MODE" = "console" ]; then
    # Several helpers return data through command substitution. Keep live
    # diagnostics on stderr so they remain visible without contaminating the
    # helper's stdout return value (for example, a numeric VM ID).
    printf '%s %s\n' "$(date)" "$1" >&2
  else
    printf '%s %s\n' "$(date)" "$1" >> "$DIR/temp_process_machine.log"
  fi
}

tempLog "Starting process_machine.sh script..."

get_machine_name() {
  echo "$(echo "$CURR_MACHINE_DATA" | jq -r ".name")"
}

useTempBackupStorage=$(echo "$CURR_MACHINE_DATA" | jq -r ".useTempBackupStorage")
suppressErrorIfSuspended=$(echo "$CURR_MACHINE_DATA" | jq -r ".suppressErrorIfSuspended")

tempLog "useTempBackupStorage flag is set to $useTempBackupStorage"
tempLog "Temporary backup storage path is set to $TEMP_BACKUP_STORAGE_PATH"
tempLog "suppressErrorIfSuspended flag is set to $suppressErrorIfSuspended"

# --- Helper to run noninteractive ESXi commands through the pinned host key ---
esxi_cmd() {
  plink -ssh -batch \
    -hostkey "$esxiHostKey" \
    -pw "$esxiPassword" \
    "$esxiLogin@$esxiIpAddress" \
    "$@" </dev/null
}

getMachineIdByName() {
  local machineName="$1"
  local vmachines=()
  local machine=""
  local machineId=""

  local commandOutput commandResult
  commandOutput=$(esxi_cmd "vim-cmd vmsvc/getallvms" 2>&1)
  commandResult=$?
  tempLog "getMachineIdByName command output ${commandOutput}"

  if [ "$commandResult" -ne 0 ]; then
    tempLog "getMachineIdByName ESXi command failed with exit code $commandResult"
    return 1
  fi

  # Keep only lines after 'Annotation' and parse "id:name"
  local allMachines
  allMachines=$(echo "$commandOutput" | ex -s +"/Annotation/norm d1G" +%p -cq! /dev/stdin)

  vmachines=($(echo "$allMachines" | awk '{if ($1 > 0) print $1":"$2}'))

  for id2Name in "${vmachines[@]}"; do
    machine=$(echo "$id2Name" | grep "$machineName")
    if [ "$machine" != "" ]; then
      break
    fi
  done

  machineId=$(echo "$machine" | awk -F: '{print $1}')

  if [ "$machineId" != "" ]; then
    echo "$machineId"
  else
    tempLog "getMachineIdByName call failed, no machine ID was found for name $machineName"
    exit 1
  fi
}

getMachineStatusById() {
  local possiblePowerState=("$POWERED_ON" "$POWERED_OFF" "$SUSPENDED")
  local machineId="$1"
  local currentMachinePowerState=""
  local commandOutput commandResult

  commandOutput=$(esxi_cmd "vim-cmd vmsvc/power.getstate $machineId" 2>&1)
  commandResult=$?
  tempLog "getMachineStatusById command output ${commandOutput}"

  if [ "$commandResult" -ne 0 ]; then
    tempLog "getMachineStatusById ESXi command failed with exit code $commandResult"
    return 1
  fi

  for powerState in "${possiblePowerState[@]}"; do
    local machineState
    machineState=$(echo "$commandOutput" | grep "$powerState")
    if [ "$machineState" != "" ]; then
      currentMachinePowerState="$powerState"
      break
    fi
  done
  echo "$currentMachinePowerState"
}

powerUpMachineById() {
  local machineId="$1"
  local desiredState="$POWERED_ON"
  local attempts=5
  local interval=15

  tempLog "Attempting to power ON VM with ID $machineId"

  # Check current state first (idempotence)
  local currentState
  currentState=$(getMachineStatusById "$machineId")

  if [ "$currentState" == "$POWERED_ON" ]; then
    tempLog "VM $machineId is already in state '$POWERED_ON'. Skipping power on."
    return 0
  fi

  tempLog "Current VM state is '$currentState'. Sending power.on command."

  local commandOutput
  commandOutput=$(esxi_cmd "vim-cmd vmsvc/power.on $machineId" 2>&1)
  tempLog "powerUpMachineById power.on output: ${commandOutput}"

  # Wait loop: check that VM actually transitions to POWERED_ON
  for ((i = 1; i <= attempts; i++)); do
    sleep "$interval"
    currentState=$(getMachineStatusById "$machineId")

    tempLog "Power-on check $i/$attempts: VM state is '$currentState'"

    if [ "$currentState" == "$desiredState" ]; then
      tempLog "VM $machineId successfully reached state '$POWERED_ON'"
      return 0
    fi
  done

  tempLog "Failed to power ON VM $machineId after $attempts attempts"
  return 1
}

powerDownMachineById() {
  local machineId="$1"
  local noVMToolsErr="VMware Tools is not running in this virtual machine"
  local commandOutput

  commandOutput=$(esxi_cmd "vim-cmd vmsvc/power.shutdown $machineId" 2>&1)
  tempLog "powerDownMachineById (shutdown) command output ${commandOutput}"

  sleep 5

  local possibleNoVMToolsErr
  possibleNoVMToolsErr=$(echo "$commandOutput" | grep "$noVMToolsErr")
  # If VM does not have VM tools installed, we will get the error:
  if [ "$possibleNoVMToolsErr" != "" ]; then
    tempLog "VM does not have VM tools installed, we will try to power it down using power.off command."
    commandOutput=$(esxi_cmd "vim-cmd vmsvc/power.off $machineId" 2>&1)
    tempLog "powerDownMachineById (power.off) command output ${commandOutput}"
  fi

  # waiting up to 5 * 30 seconds for machine to power off.
  local attempts=5
  local interval=30

  for ((i = 1; i <= attempts; i++)); do
    sleep "$interval"
    local currentMachineState
    currentMachineState=$(getMachineStatusById "$machineId")

    if [ "$currentMachineState" == "$POWERED_OFF" ]; then
      tempLog "VM $machineId reached state '$POWERED_OFF' after shutdown"
      break
    fi
  done
}

sleep 1

# --- Probe temp storage if enabled ---
if [ "$useTempBackupStorage" == "y" ]; then
  tempProbeFolder=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
  tempProbePath="$TEMP_BACKUP_STORAGE_PATH/$tempProbeFolder"

  tempLog "Probing temporary backup storage path $TEMP_BACKUP_STORAGE_PATH, creating directory $tempProbeFolder"

  if ! mkdir -p "$tempProbePath"; then
    tempLog "Failed to create probe directory $tempProbePath"
    tempLog "Terminating process_machine.sh script..."
    exit 1
  fi

  tempLog "Probe directory $tempProbePath created, now removing it."

  if ! rm -rf "$tempProbePath"; then
    tempLog "Failed to remove probe directory $tempProbePath"
    tempLog "Terminating process_machine.sh script..."
    exit 1
  fi

  tempLog "Temporary backup storage path $TEMP_BACKUP_STORAGE_PATH passed probe (create+delete)."
fi

# --- Backup directory layout ---
machineName=$(get_machine_name)
stagingName="___$machineName"

finalDir="$CURRENT_MOUNT_PATH/$machineName"         # /mnt/NAS/TEST
stagingFinalDir="$CURRENT_MOUNT_PATH/$stagingName"  # /mnt/NAS/___TEST

if [ "$useTempBackupStorage" == "y" ]; then
  # ovftool writes to local temp
  workBackupDir="$TEMP_BACKUP_STORAGE_PATH/$stagingName"
else
  # ovftool writes directly to NAS staging dir
  workBackupDir="$stagingFinalDir"
fi

tempLog "workBackupDir is set to '$workBackupDir'"
tempLog "stagingFinalDir is set to '$stagingFinalDir'"
tempLog "finalDir is set to '$finalDir'"

# Clean and create working directory
if [ -d "$workBackupDir" ]; then
  tempLog "Removing existing work directory '$workBackupDir'"
  rm -rf "$workBackupDir"
fi

# Making sure we have the machine available.
machineId=$(getMachineIdByName "$(get_machine_name)")

tempLog "Creating work directory '$workBackupDir'"
mkdir -p "$workBackupDir"

if [ ! -d "$workBackupDir" ]; then
  tempLog "Failed to create work directory '$workBackupDir'"
  tempLog "Terminating process_machine.sh script..."
  exit 1
fi

# --- Get VM ID & power state ---
tempLog "Getting VM ID from esxi server for machine named $(get_machine_name)"



if [ "$machineId" == "" ]; then
  tempLog "Getting VM ID from esxi server for machine named $(get_machine_name) has failed."
  tempLog "Terminating process_machine.sh script..."
  rm -rf "$workBackupDir"
  exit 1
fi

tempLog "VM ID from esxi server appears to be $machineId for machine named $(get_machine_name)"
tempLog "Getting VM power state from esxi server for VM ID $machineId"

initialMachinePowerState="$(getMachineStatusById "$machineId")"
currentMachinePowerState="$initialMachinePowerState"

if [ "$currentMachinePowerState" == "" ]; then
  tempLog "Getting VM power state from esxi server for VM ID $machineId has failed."
  tempLog "Terminating process_machine.sh script..."
  rm -rf "$workBackupDir"
  exit 1
fi

tempLog "VM power state from esxi server for VM ID $machineId appears to be ${currentMachinePowerState}"

# Once the original state is known, any later error or interruption must try to
# return a VM that started powered on to that state. This protects failures in
# ovftool, staging, promotion, and other paths added in the future.
restore_original_power_state_on_exit() {
  local exitCode=$?
  trap - EXIT INT TERM

  if [ "$exitCode" -ne 0 ] && \
     [ "$initialMachinePowerState" == "$POWERED_ON" ] && \
     [ "$powerRestoreAttempted" -eq 0 ]; then
    powerRestoreAttempted=1
    tempLog "Backup is exiting with code $exitCode. Attempting to restore VM $machineId to '$POWERED_ON'."
    if powerUpMachineById "$machineId"; then
      tempLog "VM $machineId was restored to '$POWERED_ON' after the backup failure."
    else
      tempLog "CRITICAL: VM $machineId could not be restored to '$POWERED_ON' after the backup failure."
    fi
  fi

  exit "$exitCode"
}

trap restore_original_power_state_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- SUSPENDED handling ---
if [ "$currentMachinePowerState" == "$SUSPENDED" ]; then
  if [ "$suppressErrorIfSuspended" == "y" ]; then
    tempLog "VM state is ${currentMachinePowerState}, and suppressErrorIfSuspended='y' -> silently skipping backup."
    tempLog "The previous successful-backup timestamp will remain unchanged so this VM stays due."
    tempLog "Cleaning up work directory '$workBackupDir' and terminating process_machine.sh as skipped."
    rm -rf "$workBackupDir"
    exit "$BACKUP_SKIPPED"
  else
    tempLog "VM state is ${currentMachinePowerState}, suppressErrorIfSuspended!='y' -> aborting backup with error."
    tempLog "Cleaning up work directory '$workBackupDir' and terminating process_machine.sh with 1."
    rm -rf "$workBackupDir"
    exit 1
  fi
fi

# --- Power down VM if needed ---
if [ "$currentMachinePowerState" != "$POWERED_OFF" ]; then
  tempLog "VM state is ${currentMachinePowerState}, we will try to power it down."
  powerDownMachineById "$machineId"
fi

currentMachinePowerState=$(getMachineStatusById "$machineId")

if [ "$currentMachinePowerState" != "$POWERED_OFF" ]; then
  tempLog "Powering down VM $machineId failed. Current machine power state is ${currentMachinePowerState}"
  tempLog "Cleaning up work directory '$workBackupDir' and terminating process_machine.sh with 1."
  rm -rf "$workBackupDir"
  exit 1
fi

# --- Run ovftool export to workBackupDir/VM_NAME.ovf ---
urlEncodedEsxiPassword=$(printf %s "$esxiPassword" | jq -sRr @uri)

tempLog "Starting ovftool export for $machineName to '$workBackupDir/$machineName.ovf'"

"$OVFTOOL_BIN" --exportFlags=mac --noSSLVerify -ds="$dataStoreName" \
  vi://"$esxiLogin":"$urlEncodedEsxiPassword"@"$esxiIpAddress"/"$machineName" \
  "$workBackupDir"/"$machineName".ovf

result=$?
tempLog "ovftool finished with exit code $result"

if [ "$result" -ne 0 ]; then
  tempLog "ovftool export failed for $(get_machine_name) with exit code $result"
  tempLog "Cleaning up work directory '$workBackupDir'"
  rm -rf "$workBackupDir"
  tempLog "Terminating process_machine.sh script with error..."
  exit 1
fi

tempLog "ovftool export completed successfully for $(get_machine_name)"

# --- Ensure staging exists on NAS as ___VM ---
mkdir -p "$CURRENT_MOUNT_PATH"

if [ "$useTempBackupStorage" == "y" ]; then
  tempLog "useTempBackupStorage='y'. Moving local '$workBackupDir' -> NAS staging '$stagingFinalDir'"

  if [ -d "$stagingFinalDir" ]; then
    tempLog "Removing existing NAS staging dir '$stagingFinalDir'"
    rm -rf "$stagingFinalDir"
  fi

  mv "$workBackupDir" "$stagingFinalDir"
  moveResult=$?

  if [ "$moveResult" -ne 0 ]; then
    tempLog "Failed to move '$workBackupDir' to '$stagingFinalDir' (exit code $moveResult)"
    rm -rf "$workBackupDir"
    exit 1
  fi

  tempLog "Local temp backup moved to NAS staging '$stagingFinalDir'"
else
  tempLog "useTempBackupStorage='n'. Backup already stored on NAS staging '$stagingFinalDir'"
fi

# --- Promote ___VM -> VM atomically ---
tempLog "Promoting staging backup '$stagingFinalDir' to stable '$finalDir'"

if [ ! -d "$stagingFinalDir" ]; then
  tempLog "Error: staging directory '$stagingFinalDir' does not exist. Aborting promotion."
  exit 1
fi

# Before removing last good known configuration, let's make sure the VM is able to power on:

# --- Restore VM power state if it was originally ON ---
if [ "$initialMachinePowerState" == "$POWERED_ON" ]; then
  tempLog "Initial VM power state was '$initialMachinePowerState'. Attempting to power VM $machineId back on..."

  powerRestoreAttempted=1
  if ! powerUpMachineById "$machineId"; then
    tempLog "VM $machineId failed to return to state '$POWERED_ON' after backup."
    tempLog "This indicates a possible corruption/problem. We will NOT overwrite existing stable backup at '$finalDir'."

    # Clean up new backup so we don't keep a half-broken generation
    if [ -d "$stagingFinalDir" ]; then
      tempLog "Removing staging backup '$stagingFinalDir' to preserve last known good '$finalDir'."
      rm -rf "$stagingFinalDir"
    fi

    # In theory, workBackupDir has been moved already if useTempBackupStorage='y',
    # but for safety we can still try to clean it if it exists.
    if [ "$useTempBackupStorage" == "y" ] && [ -d "$workBackupDir" ]; then
      tempLog "Removing local work backup directory '$workBackupDir'."
      rm -rf "$workBackupDir"
    fi

    tempLog "Terminating process_machine.sh with error because VM did not power back on."
    exit 1
  fi
fi

# At this point either:
# - VM was originally OFF (and we don't touch it), or
# - VM was originally ON and we successfully powered it back ON.
# Now it's safe to replace the last known-good backup.

if [ -d "$finalDir" ]; then
  tempLog "Removing previous stable backup '$finalDir'"
  rm -rf "$finalDir"
fi

tempLog "Renaming '$stagingFinalDir' -> '$finalDir'"
mv "$stagingFinalDir" "$finalDir"
promoteResult=$?

if [ "$promoteResult" -ne 0 ]; then
  tempLog "Failed to rename '$stagingFinalDir' to '$finalDir' (exit code $promoteResult)"
  exit 1
fi

tempLog "Backup promotion completed: '$finalDir' now holds latest stable backup."

tempLog "Backup for $(get_machine_name) completed successfully. Exiting process_machine.sh with code 0."
exit 0
