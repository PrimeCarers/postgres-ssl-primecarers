#!/bin/bash

# exit as soon as any of these commands fail, this prevents starting a database without certificates or with the wrong volume mount path
set -e

EXPECTED_VOLUME_MOUNT_PATH="/var/lib/postgresql/data"

# check if the Railway volume is mounted to the correct path
# we do this by checking the current mount path (RAILWAY_VOLUME_MOUNT_PATH) agiant the expected mount path
# if the paths are different, we print an error message and exit
# only perform this check if this image is deployed to Railway by checking for the existence of the RAILWAY_ENVIRONMENT variable
if [ -n "$RAILWAY_ENVIRONMENT" ] && [ "$RAILWAY_VOLUME_MOUNT_PATH" != "$EXPECTED_VOLUME_MOUNT_PATH" ]; then
  echo "Railway volume not mounted to the correct path, expected $EXPECTED_VOLUME_MOUNT_PATH but got $RAILWAY_VOLUME_MOUNT_PATH"
  echo "Please update the volume mount path to the expected path and redeploy the service"
  exit 1
fi

# check if PGDATA starts with the expected volume mount path
# this ensures data files are stored in the correct location
# if not, print error and exit to prevent data loss or access issues
if [[ ! "$PGDATA" =~ ^"$EXPECTED_VOLUME_MOUNT_PATH" ]]; then
  echo "PGDATA variable does not start with the expected volume mount path, expected to start with $EXPECTED_VOLUME_MOUNT_PATH"
  echo "Please update the PGDATA variable to start with the expected volume mount path and redeploy the service"
  exit 1
fi

# --- Auto-resize filesystem to fill the volume ---
# Railway may grow the block device without resizing the filesystem.
# The device node may not exist in /dev/, so we create it from /proc info.
if command -v resize2fs &>/dev/null; then
  # Get the device path that df reports
  VOLUME_DEV=$(findmnt -n -o SOURCE "$EXPECTED_VOLUME_MOUNT_PATH" 2>/dev/null || true)

  # If the device node doesn't exist, create it from /proc/self/mountinfo
  if [ -n "$VOLUME_DEV" ] && [ ! -e "$VOLUME_DEV" ]; then
    echo "Device $VOLUME_DEV not found in container, attempting to create it..."
    DEV_INFO=$(awk -v mp="$EXPECTED_VOLUME_MOUNT_PATH" '$5==mp {print $3}' /proc/self/mountinfo 2>/dev/null || true)
    if [ -n "$DEV_INFO" ]; then
      MAJOR=$(echo "$DEV_INFO" | cut -d: -f1)
      MINOR=$(echo "$DEV_INFO" | cut -d: -f2)
      echo "Creating block device node: major=$MAJOR minor=$MINOR"
      if mknod "$VOLUME_DEV" b "$MAJOR" "$MINOR" 2>&1; then
        echo "Device node created successfully at $VOLUME_DEV"
      else
        # Try in /tmp as fallback
        VOLUME_DEV="/tmp/volume_dev_$$"
        if mknod "$VOLUME_DEV" b "$MAJOR" "$MINOR" 2>&1; then
          echo "Device node created at fallback path $VOLUME_DEV"
        else
          echo "WARNING: mknod failed — cannot create device node for resize."
          VOLUME_DEV=""
        fi
      fi
    else
      echo "WARNING: Could not read device info from /proc/self/mountinfo"
      VOLUME_DEV=""
    fi
  fi

  if [ -n "$VOLUME_DEV" ] && [ -e "$VOLUME_DEV" ]; then
    echo "Checking if filesystem on $VOLUME_DEV needs resizing..."
    if resize2fs "$VOLUME_DEV" 2>&1; then
      echo "Filesystem resize complete."
    else
      echo "WARNING: resize2fs failed (non-fatal, continuing startup)."
    fi
    echo "--- Post-resize df ---"
    df -h "$EXPECTED_VOLUME_MOUNT_PATH" 2>/dev/null || true
    # Clean up temp device node if we created one in /tmp
    case "$VOLUME_DEV" in /tmp/*) rm -f "$VOLUME_DEV" 2>/dev/null || true ;; esac
  fi
else
  echo "WARNING: resize2fs not found, skipping filesystem resize check."
fi

# --- Emergency space cleanup if volume is nearly full ---
# If available space is less than 32MB, clean up non-essential files so
# Postgres has room to create a WAL segment after crash recovery.
AVAIL_KB=$(df --output=avail "$EXPECTED_VOLUME_MOUNT_PATH" 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 32768 ]; then
  echo "WARNING: Volume has only ${AVAIL_KB}KB free (<32MB). Running emergency cleanup..."
  # Stale PID from previous crash (Postgres would remove it anyway)
  rm -f "$PGDATA/postmaster.pid" 2>/dev/null || true
  # Temporary stats — safely recreated on startup
  rm -rf "${PGDATA:?}/pg_stat_tmp"/* 2>/dev/null || true
  # Logical replication snapshots — recreated when needed
  rm -rf "${PGDATA:?}/pg_logical/snapshots"/* 2>/dev/null || true
  # Old log files (older than 1 day)
  find "$PGDATA/log" -name "*.log" -mtime +0 -delete 2>/dev/null || true
  find "$PGDATA/pg_log" -name "*.log" -mtime +0 -delete 2>/dev/null || true
  # Core dumps
  find "$PGDATA" -maxdepth 1 \( -name "core" -o -name "core.*" \) -delete 2>/dev/null || true
  NEW_AVAIL_KB=$(df --output=avail "$EXPECTED_VOLUME_MOUNT_PATH" 2>/dev/null | tail -1 | tr -d ' ')
  echo "Emergency cleanup complete. Available: ${AVAIL_KB}KB -> ${NEW_AVAIL_KB}KB"
  df -h "$EXPECTED_VOLUME_MOUNT_PATH" 2>/dev/null || true
fi

# Set up needed variables
SSL_DIR="/var/lib/postgresql/data/certs"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# Regenerate if the certificate is not a x509v3 certificate
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -noout -text -in "$SSL_DIR/server.crt" | grep -q "DNS:localhost"; then
  echo "Did not find a x509v3 certificate, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Regenerate if the certificate has expired or will expire
# 2592000 seconds = 30 days
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/server.crt"; then
  echo "Certificate has or will expire soon, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Generate a certificate if the database was initialized but is missing a certificate
# Useful when going from the base postgres image to this ssl image
if [ -f "$POSTGRES_CONF_FILE" ] && [ ! -f "$SSL_DIR/server.crt" ]; then
  echo "Database initialized without certificate, generating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# unset PGHOST to force psql to use Unix socket path
# this is specific to Railway and allows
# us to use PGHOST after the init
unset PGHOST

## unset PGPORT also specific to Railway
## since postgres checks for validity of
## the value in PGPORT we unset it in case
## it ends up being empty
unset PGPORT

# Ensure Postgres temp files are written to the persistent volume.
# NOTE: this dir must live BESIDE PGDATA, not inside it. Creating a dir inside
# PGDATA before docker-entrypoint.sh runs makes PGDATA non-empty, which causes
# initdb to refuse to initialize a fresh cluster ("directory exists but is not
# empty") — breaking first boot on a brand-new volume (e.g. an env fork).
TMPDIR="${EXPECTED_VOLUME_MOUNT_PATH}/pgtmp"
export TMPDIR
mkdir -p "$TMPDIR"
chown postgres:postgres "$TMPDIR"

# --- Startup diagnostics ---
# Log disk usage so we can diagnose "No space left on device" errors
echo "=== Disk diagnostics (startup) ==="
echo "--- df -h (all filesystems) ---"
df -h 2>/dev/null || true
echo "--- PGDATA usage ---"
du -sh "$PGDATA" 2>/dev/null || true
echo "--- PGDATA breakdown (top-level dirs) ---"
du -sh "$PGDATA"/*/ 2>/dev/null | sort -rh | head -15 || true
if [ -d "$PGDATA/pg_wal" ]; then
  echo "--- pg_wal usage ---"
  du -sh "$PGDATA/pg_wal" 2>/dev/null || true
  echo "--- pg_wal file count ---"
  find "$PGDATA/pg_wal" -type f 2>/dev/null | wc -l || true
  echo "--- pg_wal largest files ---"
  du -a "$PGDATA/pg_wal" 2>/dev/null | sort -rn | head -10 || true
fi
echo "--- inode usage ---"
df -i 2>/dev/null || true
echo "=== End disk diagnostics ==="

# --- WAL cleanup before startup ---
# After repeated crash-recovery cycles, old WAL segments can accumulate
# and fill the volume. Clean up stale xlogtemp files from prior failed
# recoveries and remove any old archive status ready files.
if [ -d "$PGDATA/pg_wal" ]; then
  STALE_TEMP=$(find "$PGDATA/pg_wal" -name 'xlogtemp.*' -type f 2>/dev/null | wc -l)
  if [ "$STALE_TEMP" -gt 0 ]; then
    echo "Cleaning up $STALE_TEMP stale xlogtemp files from pg_wal..."
    find "$PGDATA/pg_wal" -name 'xlogtemp.*' -type f -delete 2>/dev/null || true
  fi
fi

# Call the entrypoint script with the
# appropriate PGHOST & PGPORT and redirect
# the output to stdout if LOG_TO_STDOUT is true
if [[ "$LOG_TO_STDOUT" == "true" ]]; then
    /usr/local/bin/docker-entrypoint.sh "$@" 2>&1
else
    /usr/local/bin/docker-entrypoint.sh "$@"
fi