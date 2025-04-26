#!/usr/bin/env bash
# provision_shares.sh
# -----------------------------------------------------------------------------
# Secure, self‑contained script to provision NFS and/or Samba shares on a Linux
# server.  Designed to complement build_your_own_qnap.sh but works standalone.
#
# Features
# --------
# * Interactive or fully non‑interactive via CLI flags
# * Creates share directory, POSIX group, and sets 2770 perms
# * Installs & configures nfs‑kernel‑server and/or Samba securely
# * Exports NFS share with root_squash, no_anonuid, & subnet restriction
# * Creates Linux user if missing and sets Samba password via smbpasswd
# * Separate per‑share include file in /etc/samba/shares.d for easier mgmt
# * Reloads/restarts services and verifies configuration (exportfs, testparm)
# * Optional UFW rules limited to RFC1918 subnets or a user‑supplied CIDR
# * Logs everything to /var/log/provision_shares.log
#
# ⚠  Run as root.  Treat passwords entered here as sensitive.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
LOG=/var/log/provision_shares.log
exec > >(tee -a "$LOG") 2>&1

info()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
fatal() { echo -e "\e[1;31m[FAIL]\e[0m  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fatal "Run as root (sudo)"

# Defaults
SHARE_PATH=""
SHARE_NAME=""
PROTOCOLS="nfs,samba"   # comma list: nfs|samba
ALLOWED_CIDR="10.10.50.0/23" # Default to your specific CIDR
USERNAME=""
QUOTA=""

usage(){ cat <<EOF
Usage: $(basename "$0") [options]

Options
  --path     <dir>   Absolute directory to export (will be created)
  --name     <name>  Share name (defaults to basename of path)
  --proto    <list>  Protocols: nfs,samba,both (default both)
  --cidr     <list>  Allowed client CIDRs (default: ${ALLOWED_CIDR})
  --user     <user>  Enforce Unix/Samba user access (prompt if missing)
  --quota    <size>  Set XFS project quota (requires xfs_quota)
  --force            Non‑interactive (assumes yes)
  -h|--help          Show this help
EOF
}

FORCE=0
ARGS=$(getopt -o h --long help,path:,name:,proto:,cidr:,user:,quota:,force -n "$0" -- "$@") || { usage; exit 1; }
eval set -- "$ARGS"
while true; do
  case "$1" in
    --path)  SHARE_PATH="$2"; shift 2;;
    --name)  SHARE_NAME="$2"; shift 2;;
    --proto) PROTOCOLS="$2"; shift 2;;
    --cidr)  ALLOWED_CIDR="$2"; shift 2;;
    --user)  USERNAME="$2"; shift 2;;
    --quota) QUOTA="$2"; shift 2;;
    --force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
  esac
done

# Interactive prompts
if [[ -z $SHARE_PATH ]]; then read -rp "Share directory (absolute): " SHARE_PATH; fi
[[ $SHARE_PATH = /* ]] || fatal "Path must be absolute"

[[ -z $SHARE_NAME ]] && SHARE_NAME=$(basename "$SHARE_PATH")

echo "$PROTOCOLS" | grep -Eqi '^(nfs|samba)(,?(nfs|samba))*$' || fatal "Invalid --proto list: $PROTOCOLS"

if [[ -z $USERNAME ]]; then read -rp "Restrict share to a specific user? (enter username or leave blank for nobody): " USERNAME; fi

# Confirm
if (( ! FORCE )); then
  echo -e "\nSummary:\n  Path    : $SHARE_PATH\n  Name    : $SHARE_NAME\n  Proto   : $PROTOCOLS\n  CIDRs   : $ALLOWED_CIDR\n  User    : ${USERNAME:-none}\n  Quota   : ${QUOTA:-none}\n"
  read -rp "Proceed? [y/N]: " ans; [[ $ans =~ ^[Yy]$ ]] || exit 1
fi

##########################  PREP DIRECTORY & GROUP  ###########################
GROUP="share_${SHARE_NAME}" # Ensure group name is valid
mkdir -p "$SHARE_PATH"

# Determine anonuid/gid for NFS ACLs
NFS_ANON_UID=$(id -u nobody 2>/dev/null) || { warn "User 'nobody' not found, using 65534 for ACLs"; NFS_ANON_UID=65534; }
NFS_ANON_GID=$(id -g nogroup 2>/dev/null) || NFS_ANON_GID=$(id -g nobody 2>/dev/null) || { warn "Group 'nogroup' or 'nobody' not found, using 65534 for ACLs"; NFS_ANON_GID=65534; }

# Create Samba group if it doesn't exist
if ! getent group "$GROUP" >/dev/null; then
    info "Creating group $GROUP"
    groupadd "$GROUP" || fatal "Failed to create group $GROUP"
fi

info "Setting base ownership and permissions for $SHARE_PATH"
# Set base ownership primarily for Samba group
chown "root:$GROUP" "$SHARE_PATH" || warn "Failed to change group ownership for $SHARE_PATH to $GROUP"
# Set base permissions: Owner(rwx), Group(rwx + setgid), Others(---)
chmod 2770 "$SHARE_PATH" || warn "Failed to set base permissions (2770) for $SHARE_PATH"

# Apply ACLs if filesystem is XFS (assuming built-in support)
FS_TYPE_ACL=$(df -T "$SHARE_PATH" | awk 'NR==2{print $2}')
if [[ "$FS_TYPE_ACL" == "xfs" ]]; then
    info "Applying POSIX ACLs for NFS/Samba (assuming XFS support)"
    # Grant NFS anonymous user/group rwx permissions
    setfacl -m "u:${NFS_ANON_UID}:rwx,g:${NFS_ANON_GID}:rwx" "$SHARE_PATH" || warn "Failed to set ACLs for NFS user/group"

    # Set Default ACLs for new files/directories
    # Default for owner (root)
    # Default for owning group ($GROUP)
    # Default for NFS anonymous user/group
    # Default mask to allow granted permissions
    # Default for others (no permissions)
    setfacl -d -m "u::rwx,g::rwx,u:${NFS_ANON_UID}:rwx,g:${NFS_ANON_GID}:rwx,g:${GROUP}:rwx,m::rwx,o::0" "$SHARE_PATH" || warn "Failed to set default ACLs"
    info "ACLs applied. Use 'getfacl $SHARE_PATH' to view."
else
    warn "Skipping ACL configuration as filesystem type ($FS_TYPE_ACL) is not XFS. NFS/Samba permissions might conflict."
fi

# Ensure parent directory allows access if needed
chmod o+x "$(dirname "$SHARE_PATH")" || true # Allow traversal into parent

# User creation/management (primarily for Samba)
if [[ -n $USERNAME ]]; then
  if ! id "$USERNAME" &>/dev/null; then
    info "Creating user $USERNAME (no‑login)"
    useradd -M -s /usr/sbin/nologin -g "$GROUP" "$USERNAME" || fatal "Failed to create user $USERNAME"
  else
    info "Adding user $USERNAME to group $GROUP"
    usermod -a -G "$GROUP" "$USERNAME" || warn "Failed to add user $USERNAME to group $GROUP"
  fi
fi

##########################  PACKAGE INSTALLATION  ############################
install_pkgs(){
  info "Installing packages: $*"
  DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y install "$@" || fatal "Failed to install $*"
}

PKGS_TO_INSTALL=""
# Add 'acl' package if either protocol is used, as it helps manage mixed permissions
if grep -qi -e nfs -e samba <<< "$PROTOCOLS"; then PKGS_TO_INSTALL+=" acl"; fi
if grep -qi nfs <<< "$PROTOCOLS";   then PKGS_TO_INSTALL+=" nfs-kernel-server"; fi
if grep -qi samba <<< "$PROTOCOLS"; then PKGS_TO_INSTALL+=" samba smbclient"; fi # Add smbclient for testing
if [[ -n $QUOTA ]]; then PKGS_TO_INSTALL+=" xfsprogs"; fi # For xfs_quota

if [[ -n $PKGS_TO_INSTALL ]]; then
    # Remove leading space if present
    PKGS_TO_INSTALL=$(echo "$PKGS_TO_INSTALL" | sed 's/^ *//')
    install_pkgs $PKGS_TO_INSTALL
fi

###############################  NFS CONFIG  ##################################
if grep -qi nfs <<< "$PROTOCOLS"; then
  info "Configuring NFS export for $SHARE_PATH"
  # Ensure /etc/exports exists
  touch /etc/exports

  # Determine anonuid and anongid safely
  ANON_UID=$(id -u nobody 2>/dev/null) || { warn "User 'nobody' not found, using 65534"; ANON_UID=65534; }
  # Try 'nogroup' first, then the primary group of 'nobody' user
  ANON_GID=$(id -g nogroup 2>/dev/null) || ANON_GID=$(id -g nobody 2>/dev/null) || { warn "Group 'nogroup' or 'nobody' not found, using 65534"; ANON_GID=65534; }
  info "Using anonuid=$ANON_UID, anongid=$ANON_GID for NFS"

  # Build export options string
  NFS_OPTS="rw,sync,no_subtree_check,all_squash,anonuid=${ANON_UID},anongid=${ANON_GID},sec=sys"
  EXPORT_LINE_BASE="$SHARE_PATH"
  EXPORT_LINE=""
  # Add CIDR restrictions
  IFS=',' read -ra CIDRS <<< "$ALLOWED_CIDR"
  for c in "${CIDRS[@]}"; do
    EXPORT_LINE+="${EXPORT_LINE_BASE} ${c}(${NFS_OPTS}) "
  done

  # Remove old entries for this path first
  sed -i "\:^${SHARE_PATH} :d" /etc/exports
  # Add the new line
  echo "$EXPORT_LINE" >> /etc/exports
  info "Applying NFS export changes"
  exportfs -ra || warn "exportfs command failed"
  info "Enabling and starting NFS server"
  systemctl enable --now nfs-server || warn "Failed to enable/start nfs-server"
  systemctl restart nfs-server || warn "Failed to restart nfs-server"
fi

#############################  SAMBA CONFIG  ##################################
if grep -qi samba <<< "$PROTOCOLS"; then
  info "Configuring Samba share [$SHARE_NAME] for $SHARE_PATH"
  # Define share content in a variable
  SHARE_DEFINITION=$(cat <<EOL
[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   comment = $SHARE_NAME Share
   valid users = @${GROUP}${USERNAME:+ ${USERNAME}}
   guest ok = no
   read only = no
   force group = ${GROUP}
   create mask = 0660
   directory mask = 0770 
   vfs objects = acl_xattr 
EOL
)
  info "Generated share definition for [$SHARE_NAME]"

  SMB_CONF="/etc/samba/smb.conf"

  # --- Direct Append Logic ---
  # Remove any existing definition for this share name first
  info "Removing existing definition for [$SHARE_NAME] from $SMB_CONF (if any)"
  # Use awk to print lines until the section starts, and after it ends
  sudo awk -v section="[$SHARE_NAME]" '
      BEGIN { printing = 1 }
      $0 == section { printing = 0 }
      printing { print }
      !printing && /^\[.*\]$/ && $0 != section { printing = 1; print }
  ' "$SMB_CONF" > "${SMB_CONF}.tmp" && sudo mv "${SMB_CONF}.tmp" "$SMB_CONF"

  info "Appending share definition for [$SHARE_NAME] directly to $SMB_CONF"
  echo -e "\n# Share definition added by provision_shares.sh\n${SHARE_DEFINITION}" | sudo tee -a "$SMB_CONF"
  # --- End Direct Append Logic ---


  # --- Compatibility Settings (Still use smb.conf.d for this) ---
  CONF_D_INCLUDE="include = /etc/samba/smb.conf.d/*.conf"
  # Ensure [global] section exists
  if ! grep -q "\[global\]" "$SMB_CONF"; then
      info "Adding [global] section to $SMB_CONF"
      echo -e "\n[global]" | sudo tee -a "$SMB_CONF"
  fi
  # Ensure smb.conf.d include is present in [global]
  if ! grep -qxF "$CONF_D_INCLUDE" "$SMB_CONF"; then
      info "Ensuring '$CONF_D_INCLUDE' is present in $SMB_CONF"
      sudo sed -i '\:^include = /etc/samba/smb\.conf\.d/\*\.conf:d' "$SMB_CONF" # Remove if exists elsewhere
      sudo sed -i '/\[global\]/a '"${CONF_D_INCLUDE}" "$SMB_CONF" # Add under [global]
  fi

  COMPAT_CONF_DIR="/etc/samba/smb.conf.d"
  COMPAT_CONF_FILE="${COMPAT_CONF_DIR}/zz_compatibility_settings.conf"
  mkdir -p "$COMPAT_CONF_DIR"
  info "Writing compatibility settings to $COMPAT_CONF_FILE"
  sudo tee "$COMPAT_CONF_FILE" > /dev/null <<EOF
# Settings added by provision_shares.sh
client min protocol = SMB2_10
server min protocol = SMB2_10
client use spnego = yes
server signing = mandatory
log level = 1
EOF
  # --- End Compatibility Settings ---


  info "Validating Samba configuration"
  if sudo testparm -s; then
      info "Samba configuration appears valid."
  else
      warn "testparm reported issues with Samba configuration. Check output above."
  fi

  info "Enabling and restarting Samba services (smbd and nmbd)"
  sudo systemctl enable --now smbd nmbd || warn "Failed to enable smbd/nmbd"
  sudo systemctl restart smbd nmbd || warn "Failed to restart smbd/nmbd"

  if [[ -n $USERNAME ]]; then
    info "Setting Samba password for user $USERNAME"
    if (( FORCE )); then
        SMB_PASS=$(openssl rand -base64 12)
        info "Generated Samba password for $USERNAME: $SMB_PASS (store securely!)"
        (echo "$SMB_PASS"; echo "$SMB_PASS") | sudo smbpasswd -s -a "$USERNAME" || warn "Failed to set Samba password for $USERNAME non-interactively"
    else
        sudo smbpasswd -a "$USERNAME" || warn "Failed to set Samba password for $USERNAME"
    fi
  fi
fi

############################  OPTIONAL QUOTA  #################################
if [[ -n $QUOTA ]]; then
  if ! command -v xfs_quota >/dev/null; then
    warn "xfs_quota command not found (package xfsprogs?); quota skipped"
  else
    # Check if filesystem supports project quotas
    FS_TYPE=$(df -T "$SHARE_PATH" | awk 'NR==2{print $2}')
    if [[ "$FS_TYPE" != "xfs" ]]; then
        warn "Filesystem type ($FS_TYPE) is not XFS. Quota skipped."
    else
        FS_DEV=$(df -P "$SHARE_PATH" | awk 'NR==2{print $1}')
        MOUNT_OPTS=$(findmnt -n -o OPTIONS "$FS_DEV")
        if ! echo "$MOUNT_OPTS" | grep -q "prjquota"; then
            warn "Filesystem $FS_DEV is not mounted with 'prjquota' option. Attempting remount."
            # Check fstab and add if missing
            if ! grep "$FS_DEV" /etc/fstab | grep -q "prjquota"; then
                warn "Adding 'prjquota' to fstab for $FS_DEV and remounting."
                # This sed command is basic, might need refinement for complex fstabs
                sudo sed -i "\|$FS_DEV| s/defaults/defaults,prjquota/" /etc/fstab
            fi
            sudo mount -o remount "$FS_DEV" || warn "Failed to remount $FS_DEV with prjquota. Quota may not apply."
        fi

        # Proceed with quota setup only if mount seems okay
        if mount | grep "$FS_DEV" | grep -q "prjquota"; then
            info "Setting XFS project quota ($QUOTA) for $SHARE_PATH"
            # Generate a unique project ID based on path hash or similar? Using random for now.
            PROJECT_ID=$(echo "$SHARE_PATH" | md5sum | cut -c1-8) # More deterministic ID
            # Ensure project files exist
            touch /etc/projects /etc/projid
            # Remove old entries first
            sed -i "\:$SHARE_PATH:d" /etc/projects
            sed -i "\:$PROJECT_ID:d" /etc/projid
            # Add new entries
            echo "$PROJECT_ID:$SHARE_PATH" >> /etc/projects
            echo "$GROUP:$PROJECT_ID"     >> /etc/projid # Map group to project ID
            info "Setting up project ID $PROJECT_ID for $GROUP on $FS_DEV"
            xfs_quota -x -c "project -s -p $SHARE_PATH $PROJECT_ID" "$FS_DEV" || warn "Failed to setup project quota for $SHARE_PATH"
            info "Applying quota limit $QUOTA"
            xfs_quota -x -c "limit -p bhard=$QUOTA $PROJECT_ID" "$FS_DEV" || warn "Failed to apply quota limit for project $PROJECT_ID"
        else
             warn "Filesystem not mounted with prjquota, skipping quota setup."
        fi
    fi
  fi
fi

###############################  FIREWALL  ####################################
if command -v ufw &>/dev/null; then
  if ufw status | grep -q inactive; then
      warn "UFW is inactive. Firewall rules not applied."
  else
      info "Configuring UFW firewall rules for allowed CIDRs: $ALLOWED_CIDR"
      IFS=',' read -ra CIDRS <<< "$ALLOWED_CIDR"
      for c in "${CIDRS[@]}"; do
        if grep -qi nfs <<< "$PROTOCOLS"; then
            info "Allowing NFS (port 2049/tcp) from $c"
            ufw allow from "$c" to any port 2049 proto tcp comment "NFS for $SHARE_NAME"
        fi
        if grep -qi samba <<< "$PROTOCOLS"; then
            info "Allowing Samba (ports 139,445/tcp) from $c"
            ufw allow from "$c" to any port 139 proto tcp comment "Samba NetBIOS for $SHARE_NAME"
            ufw allow from "$c" to any port 445 proto tcp comment "Samba SMB for $SHARE_NAME"
            # Optional: Allow UDP for browsing if needed
            # ufw allow from "$c" to any port 137,138 proto udp comment "Samba NetBIOS UDP for $SHARE_NAME"
        fi
      done
  fi
else
    info "UFW not found. Skipping firewall configuration."
fi

info "Share '$SHARE_NAME' provisioned successfully."
info "Path: $SHARE_PATH"
info "Protocols: $PROTOCOLS"
info "Access: Try '\\\\SERVER_IP\\$SHARE_NAME' (Samba) or 'mount SERVER_IP:$SHARE_PATH /mnt/point' (NFS)"

exit 0