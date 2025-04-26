#!/usr/bin/env bash
# build_your_own_qnap.sh
#
# A comprehensive script to create a QNAP‑style storage pool on any Linux server
# using mdadm, LVM2 and (optionally) an SSD cache.
#
# Key features
# ------------
# * Interactive or non‑interactive (all parameters can be supplied as CLI flags)
# * Supports RAID 0/1/5/6/10 with mdadm
# * Automatically creates an LVM volume group on the array
# * Optional LVM cache pool using fast drives (NVMe / SSD)
# * Creates and mounts an XFS filesystem (default) or ext4/btrfs
# * Generates /etc/mdadm.conf and /etc/fstab entries
# * Logs every action to /var/log/build_qnap.log
#
# ⚠  WARNING: THIS SCRIPT ERASES DATA ON THE SELECTED DRIVES.  ⚠
# ------------------------------------------------------------------------------
# Requirements: bash ≥4, mdadm, lvm2, util‑linux (lsblk), (optional) whiptail
#
# Example non‑interactive:
#   sudo ./build_your_own_qnap.sh \
#        --data /dev/sdb,/dev/sdc,/dev/sdd \
#        --raid 5 \
#        --cache /dev/nvme0n1 \
#        --fs xfs
#
###############################################################################
set -Eeuo pipefail
LOGFILE=/var/log/build_qnap.log
exec > >(tee -a "$LOGFILE") 2>&1

###############################   UTILITIES   ##################################
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*";  }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*";  }
fatal() { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || fatal "Run as root (sudo)"; }

dep_check() {
  for cmd in mdadm lvcreate vgcreate pvcreate lsblk mkfs.xfs mkfs.ext4 blkid; do
    command -v "$cmd" >/dev/null || fatal "Missing dependency: $cmd"
  done
  # Check for btrfs if requested
  if [[ "$FILESYS" == "btrfs" ]]; then
    command -v mkfs.btrfs >/dev/null || fatal "Missing dependency: mkfs.btrfs"
  fi
}

list_block_devices() {
  lsblk -dno NAME,SIZE,MODEL,ROTA | awk '{printf "/dev/%s\t%s\t%s\t%s\n",$1,$2,$3,($4==1?"HDD":"SSD")}'
}

parse_csv() { tr ',' ' ' <<< "$1"; }

###############################   PARSING   ####################################
DATA_DRIVES=""
CACHE_DRIVES=""
RAID_LEVEL=""
FILESYS="xfs"
VG_NAME="qnap-vg"
LV_NAME="qnap-data"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options
  --data   <list>   Comma‑separated list of data drives (e.g. /dev/sdb,/dev/sdc)
  --cache  <list>   Comma‑separated list of cache drives (optional)
  --raid   <level>  RAID level: 0,1,5,6,10
  --fs     <type>   Filesystem (xfs|ext4|btrfs). Default: xfs
  --force           Skip interactive confirmation
  -h, --help        Show this help and exit
EOF
}

FORCE=0
ARGS=$(getopt -o h --long help,data:,cache:,raid:,fs:,force -n "$0" -- "$@") || { usage; exit 1; }
eval set -- "$ARGS"
while true; do
  case "$1" in
    --data)  DATA_DRIVES="$2"; shift 2 ;;
    --cache) CACHE_DRIVES="$2"; shift 2 ;;
    --raid)  RAID_LEVEL="$2";  shift 2 ;;
    --fs)    FILESYS="$2";     shift 2 ;;
    --force) FORCE=1;          shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
  esac
done

###############################   INTERACTIVE   ################################
need_root
dep_check

if [[ -z $DATA_DRIVES ]]; then
  info "Detected block devices:"
  list_block_devices | column -t
  read -rp "Enter *data* drive list (comma separated): " DATA_DRIVES
fi

if [[ -z $RAID_LEVEL ]]; then
  read -rp "Enter RAID level [0|1|5|6|10]: " RAID_LEVEL
fi

# Validate RAID level
if [[ ! $RAID_LEVEL =~ ^(0|1|5|6|10)$ ]]; then
  fatal "Invalid RAID level: $RAID_LEVEL. Must be 0, 1, 5, 6, or 10"
fi

# Validate minimum drive requirements for RAID level
IFS=' ' read -r -a DATA <<< "$(parse_csv "$DATA_DRIVES")"
if (( ${#DATA[@]} < 1 )); then fatal "No data drives specified"; fi

min_drives=1
case "$RAID_LEVEL" in
  0) min_drives=2 ;;
  1) min_drives=2 ;;
  5) min_drives=3 ;;
  6) min_drives=4 ;;
  10) min_drives=4 ;;
esac

if (( ${#DATA[@]} < min_drives )); then
  fatal "RAID $RAID_LEVEL requires at least $min_drives drives, but only ${#DATA[@]} provided"
fi

if [[ -z $CACHE_DRIVES ]]; then
  read -rp "Enter cache drive list (comma separated, or leave blank): " CACHE_DRIVES || true
fi

# Validate filesystem type
if [[ ! $FILESYS =~ ^(xfs|ext4|btrfs)$ ]]; then
  fatal "Invalid filesystem: $FILESYS. Must be xfs, ext4, or btrfs"
fi

# Validate drives
for d in "${DATA[@]}"; do [[ -b $d ]] || fatal "Device $d does not exist"; done

# Find available MD device
ARRAY_DEV="/dev/md0"
for i in {0..9}; do
  if [[ ! -e /dev/md$i ]]; then
    ARRAY_DEV="/dev/md$i"
    break
  fi
done

# Confirm before proceeding
if (( FORCE != 1 )); then
  warn "WARNING: This will ERASE ALL DATA on drives: ${DATA[*]}"
  if [[ -n $CACHE_DRIVES ]]; then
    warn "AND on cache drives: $CACHE_DRIVES"
  fi
  read -rp "Continue? [y/N] " confirm
  [[ $confirm =~ ^[Yy] ]] || fatal "Operation cancelled by user"
fi

# Prepare drives by clearing any existing RAID metadata or signatures
info "Preparing drives for RAID..."
for drive in "${DATA[@]}"; do
  info "Clearing metadata from $drive..."
  # Stop/remove from any arrays and zero superblock
  mdadm --stop "$drive" &>/dev/null || true
  mdadm --zero-superblock "$drive" &>/dev/null || true
  # Clear all signatures
  wipefs -af "$drive" &>/dev/null || warn "Could not completely clear $drive"
  # Sleep briefly to ensure device is ready
  sleep 1
done

info "Creating RAID${RAID_LEVEL} array ${ARRAY_DEV} with drives: ${DATA[*]}"
# Better error handling for mdadm creation
set +e
mdadm --create "$ARRAY_DEV" --level="$RAID_LEVEL" --raid-devices="${#DATA[@]}" "${DATA[@]}" --force --run <<< "yes" 2>/tmp/mdadm_error
mdadm_status=$?
set -e

if [[ $mdadm_status -ne 0 ]]; then
  cat /tmp/mdadm_error >&2
  # Clean up the possibly partially created array
  mdadm --stop "$ARRAY_DEV" &>/dev/null || true
  fatal "Failed to create RAID array (exit code $mdadm_status)"
fi

# Double-check that array exists and is properly created
if ! mdadm --detail "$ARRAY_DEV" &>/dev/null; then
  fatal "RAID array not found after creation"
fi

info "RAID array $ARRAY_DEV successfully created."

# Allow more time for array sync on NVMe drives which are fast
info "Waiting for array to sync..."
timeout 60 mdadm --wait "$ARRAY_DEV" || warn "mdadm --wait timed out, but continuing..."

# Save mdadm config
info "Saving mdadm configuration"
mdadm --detail --scan >> /etc/mdadm.conf || warn "Failed to update mdadm.conf"
update-initramfs -u || warn "Failed to update initramfs"

# LVM setup
info "Setting up LVM on $ARRAY_DEV"
pvcreate "$ARRAY_DEV" || fatal "Failed to create physical volume"
vgcreate "$VG_NAME" "$ARRAY_DEV" || fatal "Failed to create volume group"
lvcreate -n "$LV_NAME" -l 100%FREE "$VG_NAME" || fatal "Failed to create logical volume"

# Optional cache
if [[ -n $CACHE_DRIVES ]]; then
  IFS=' ' read -r -a CACHE <<< "$(parse_csv "$CACHE_DRIVES")"
  for c in "${CACHE[@]}"; do [[ -b $c ]] || fatal "Cache device $c missing"; done
  info "Adding cache devices: ${CACHE[*]}"
  
  # Create PVs on cache drives
  pvcreate "${CACHE[@]}" || fatal "Failed to create PVs on cache devices"
  vgextend "$VG_NAME" "${CACHE[@]}" || fatal "Failed to extend VG with cache devices"

  # Create cache pool with cache drives - split space for metadata and cache data
  CACHE_DEV="${CACHE[0]}"
  info "Creating cache pool on $CACHE_DEV"
  
  # Get the size of the cache device in extents
  CACHE_SIZE=$(vgs --noheadings --units e --nosuffix -o vg_free "$VG_NAME")
  CACHE_META_SIZE=$((CACHE_SIZE / 10)) # Use 10% for metadata
  CACHE_DATA_SIZE=$((CACHE_SIZE - CACHE_META_SIZE))
  
  # Create cache metadata LV
  lvcreate --size "${CACHE_META_SIZE}e" -n cache_meta "$VG_NAME" || fatal "Failed to create cache metadata LV"
  
  # Create cache data LV using the rest of available space
  lvcreate --size "${CACHE_DATA_SIZE}e" -n cache_data "$VG_NAME" || fatal "Failed to create cache data LV"
  
  # Combine cache metadata and cache data into a cache pool
  lvconvert --type cache-pool --poolmetadata "$VG_NAME/cache_meta" "$VG_NAME/cache_data" || fatal "Failed to create cache pool"
  
  # Attach cache pool to data volume
  lvconvert --type cache --cachepool "$VG_NAME/cache_data" "$VG_NAME/$LV_NAME" || fatal "Failed to attach cache pool"
  
  info "Cache setup completed successfully"
fi

# Filesystem
info "Creating $FILESYS filesystem on /dev/$VG_NAME/$LV_NAME"
mkfs."$FILESYS" "/dev/$VG_NAME/$LV_NAME" || fatal "Failed to create filesystem"

mkdir -p /srv/storage
UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_NAME") || fatal "Failed to get UUID"
echo "UUID=$UUID /srv/storage $FILESYS defaults 0 2" >> /etc/fstab
mount -a || fatal "Failed to mount filesystem"

info "Storage is ready and mounted at /srv/storage"
info "mdadm details:"
mdadm --detail "$ARRAY_DEV" | tee /etc/qnap_array_info.txt

info "Completed successfully."
df -h /srv/storage
exit 0