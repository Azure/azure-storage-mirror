#!/bin/bash -e

MOUNTPOINT=$1
STORAGE_ACCOUNT=$2
CONTAINER_NAME=$3
TEMPPATH=$4
REMOUNT=$5

if [ -z "$STORAGE_ACCOUNT" ]; then
    echo "The storage account is empty" 2>&1
    exit 1
fi

if [ "$REMOUNT" == "y" ] && mountpoint -q $MOUNTPOINT; then
   echo "umount $MOUNTPOINT"
   sudo umount $MOUNTPOINT
fi

if ! grep -q '^user_allow_other' /etc/fuse.conf; then
   echo user_allow_other | sudo tee -a /etc/fuse.conf > /dev/null
fi

if ! mountpoint $MOUNTPOINT; then
    if [ ! -e $MOUNTPOINT ]; then
     sudo mkdir -p "$MOUNTPOINT"
     sudo chmod a+rw "$MOUNTPOINT"
    fi
    
    export AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
    export AZURE_STORAGE_AUTH_TYPE=MSI
    sudo -E blobfuse "$MOUNTPOINT" --container-name="$CONTAINER_NAME" --tmp-path="$TEMPPATH" -o attr_timeout=240 -o entry_timeout=240 -o negative_timeout=120 -o allow_other
    ls -l $MOUNTPOINT
    sleep 10
fi

# Validate the mount results
if ! mountpoint -q $MOUNTPOINT; then
    echo "Failed to mount $MOUNTPOINT" 1>&2
    exit 1
fi
