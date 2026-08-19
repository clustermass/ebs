#!/bin/bash
# pass Synology mac address, broadcast address and target machine ip address
WAIT_TIME=180 #seconds to wait for the device to boot up after WOL is sent
ATTEMPTS=3 #attempts to try to wake up the device

MAC_ADDRESS=$1
BROADCAST_ADDRESS=$2
IP_ADDRESS=$3
MODE="${4:-}"

is_machine_available () {
  ping "$1" -w 3 -c 2 >> /dev/null
  local result=$?
    if [ $result == 0 ]; then
    	echo 1    
    else
    	echo 0
	fi
}

# Setup validation uses send-only mode so it can apply its own five-minute
# polling window and guarantee a recovery attempt if interrupted.
if [ "$MODE" = "--send-only" ]; then
  wakeonlan -i "$BROADCAST_ADDRESS" "$MAC_ADDRESS"
  exit $?
fi

isMachineOn=$(is_machine_available "$IP_ADDRESS")

 if [ $isMachineOn == 1 ]; then
    # If machine is on, no need to wake it up
    ATTEMPTS=0
    exit 0
 fi

while [ $ATTEMPTS -ne 0 ]
 do
 wakeonlan -i "$BROADCAST_ADDRESS" "$MAC_ADDRESS"
 sleep $WAIT_TIME
 isMachineOn=$(is_machine_available "$IP_ADDRESS")
  if [ $isMachineOn == 1 ]; then
    # If machine booted up, we can exit
    exit 0
  else
    ((--ATTEMPTS))
  fi
 done
 exit 1
