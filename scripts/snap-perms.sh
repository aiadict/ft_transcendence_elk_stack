#!/bin/sh
set -eux

# Ensure the snapshot directory exists and is writable by the ES user (uid 1000)
mkdir -p /snapshots
chown -R 1000:0 /snapshots
chmod -R 775 /snapshots

# Show final perms for verification
ls -ld /snapshots