#!/usr/bin/env bash

PXCTL='/opt/pwx/bin/pxctl'
NODEIP=`${PXCTL} status | grep IP: | awk '{print $2}'`
NOW=`date +"%m%d%Y%H%M%S"`
LOG_FILE='/tmp/checkvols-'${NOW}'.log'

printUsage() {
  cat <<EOUSAGE
Usage:
  checkvols 
     -v <volume name or ID> [optional]
EOUSAGE
  echo "Examples: "
  echo "Check all volumes on node: checkvols"
  echo "Check for specific volume: checkvols -v testvol"
}

while getopts "h?:v:" opt; do
    case "$opt" in
    h|\?)
        printUsage
        exit 0
        ;;
    v)  VOLS=$OPTARG
        ;;
    :)
        echo "[ERROR] Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
    default)
       printUsage
       exit 1
    esac
done

log() {
  echo "$@" >> $LOG_FILE
}

run_fsck() {
  log "[INFO]: Running fsck on snapshot"
  log "[INFO]: Device path: $@"
  fsckout=`fsck -n $@ 2>&1`
  if [[ ($? -ne 0) ]]; then
    log "[ERROR]: Error running fsck: ${fsckout}"
  else
    log "[INFO]: fsck output:"
    log $fsckout
  fi
}

# Detach and delete snapshot
clean() {
  log "[INFO]: Detaching snapshot"
  detach=`${PXCTL} host detach $@ 2>&1`
  log "[INFO]: Deleting snapshot"
  delete=`${PXCTL} v delete -f $@ 2>&1`
}

# Create log file
echo "Starting checkvols script" > ${LOG_FILE}
echo "Starting checkvols script"

# Find node id
NODEID=`${PXCTL} status | grep "Node ID" | awk '{print $3}'`
# check if found node id
if [[ (-z ${NODEID}) ]]; then
    log "[ERROR]: Cannot find PX node id. Check if this is a PX node and PX is up and running."
    echo "Cannot find PX node id. Check if this is a PX node and PX is up and running."
    exit 1
fi
log "[INFO]: Checking volumes with replicas on node: $NODEID"

# If no volume name was provided find all volumes with replicas on this node
if [[ (-z ${VOLS}) ]]; then
  VOLS=`${PXCTL} v l -v --node-id ${NODEID} | grep -v SNAP-ENABLED | awk '{print $1}'`
fi
# check if found any volumes on this node
if [[ (-z ${VOLS}) ]]; then
    log "[WARNING]: Cannot find any volumes on this node."
    exit 1
fi
log "[INFO]: Checking volumes: "
log "$VOLS"

# Check state of each volume
for vol in ${VOLS}
do
  echo "Checking volume ${vol}"
  log ""
  log "[INFO]: Checking volume ${vol}"
  log "[INFO]: Creating a snapshot"
  snap=`${PXCTL} v s create --name snap_${vol} ${vol} 2>&1`
  if [[ ($? -ne 0) ]]; then
    log "[ERROR]: Cannot create snapshot: ${snap}"
    continue
  fi
  log "[INFO]: Attaching snapshot to local host"
  attach=`${PXCTL} host attach snap_${vol} | awk '{print $5}' 2>&1`
  if [[ ($? -ne 0) ]]; then
    log "[ERROR]: Error attaching snapshot: ${attach}"
    clean snap_${vol}
    continue
  fi
  # check for device path and if volume is indeed attached locally
  attachip=`${PXCTL} v i snap_${vol} | grep Attached | awk -F '[()]' '{print $2}' 2>&1`
  log "[INFO]: Attached on IP: ${attachip}"
  if [[ (${attachip} != ${NODEIP}) ]]; then
    log "[WARNING]: Shared volume attached on different node: $attachip"
    log "[WARNING]: Skipping volume, please ssh to $attachip and run 'fsck -n snap_${vol}'"
    continue
  fi
  devpath=`${PXCTL} v i snap_${vol} | grep 'Device Path' | awk '{print $4}'`
  log "Device path: ${devpath}"
  run_fsck ${devpath}
  clean snap_${vol}
done
echo "Checking volumes complete - see ${LOG_FILE} for moore details"
