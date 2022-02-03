#!/bin/bash

#
# provision vmss virtual machine
#

set -ex

source /etc/os-release

# create a partition on the 1T data disk
parted /dev/disk/azure/scsi1/lun0 --script mklabel gpt mkpart data ext4 0% 100%
sleep 10
mkfs.ext4 /dev/disk/azure/scsi1/lun0-part1
partprobe /dev/disk/azure/scsi1/lun0-part1

mkdir -p /agent
mount /dev/${datadisk}1 /agent

# Make /data symbol link
mkdir -p /agent/data
ln -sf /agent/data /data

