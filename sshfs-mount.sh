#!/usr/bin/env bash

# Usage: sshfs-mount.sh <remote> <mountpoint>
# Example: sshfs-mount.sh concolic:/home/device-admin/LibAFL/ ~/remote_concolic

if [ $# -ne 2 ]; then
    echo "Usage: $0 <remote> <mountpoint>"
    echo "Example: $0 user@host:/remote/path /local/mountpoint"
    echo "Example: $0 concolic:/home/device-admin/LibAFL/ ~/remote_concolic"
    exit 1
fi

REMOTE=$1
MOUNTPOINT=$2

# Create mount point directory if it doesn't exist
mkdir -p "$MOUNTPOINT"

# Mount the remote filesystem using sshfs
if sshfs "$REMOTE" "$MOUNTPOINT" \
    -o reconnect \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10; then
    echo "Mounted $REMOTE to $MOUNTPOINT successfully."
else
    echo "Failed to mount $REMOTE to $MOUNTPOINT."
    exit 1
fi

