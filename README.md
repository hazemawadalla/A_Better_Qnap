
# Build‑Your‑Own QNAP on Linux

Author: Hazem Awadallah hazem.awadalla@gmail.com, Independent

Two Bash scripts turn any Linux box into a **DIY QNAP‑style NAS**:

1.  `build_your_own_qnap.sh` – creates the storage pool with **mdadm** + **LVM2** and (optionally) an SSD cache.
2.  `provision_shares.sh` – layers **NFS** and/or **Samba** shares on top, with per‑share user/group management, secure defaults, and **POSIX ACLs** for fine-grained permissions on XFS filesystems.

Both are fully standalone but designed to work together.

---

## ⚡ Quick start (interactive)

```bash
# 1. Download & make them executable

git clone https://github.com/hazemawadalla/A_Better_Qnap
cd A_Better_Qnap
chmod +x build_your_own_qnap.sh provision_shares.sh

# 2. Build an array (example picks /dev/sdb /dev/sdc /dev/sdd)
#    Ensure the filesystem is XFS if you want ACL support (default)
sudo ./build_your_own_qnap.sh --fs xfs # follow the prompts

# 3. Create a share
sudo ./provision_shares.sh     # again, follow prompts
```



## Prerequisites

- Debian/Ubuntu or a compatible distro (apt‑based). RHEL/Fedora works but you must swap `apt-get` for `dnf`/`yum`.
- Packages: `mdadm`, `lvm2`, `nfs-kernel-server`, `samba`, `acl` (for ACL support), `ufw` (optional), `xfsprogs` (for XFS and quota).
- Root privileges (`sudo`).
- **XFS filesystem** on the storage volume is recommended for full ACL functionality provided by provision_shares.sh.

The storage script **wipes the selected drives**. Test in a VM before running on production iron.

---

## Script 1 – build\_your\_own\_qnap.sh

Creates a RAID array, LVM volume group, and mounts it under `/srv/storage`.

```text
Usage: build_your_own_qnap.sh [options]
  --data   <list>   Comma‑separated data drives (/dev/sdb,/dev/sdc)
  --cache  <list>   Comma‑separated SSD/NVMe cache drives (optional)
  --raid   <level>  RAID level 0|1|5|6|10
  --fs     <type>   Filesystem xfs|ext4|btrfs (default xfs)
  --force           Skip prompts (non‑interactive)
```

Example non‑interactive build (using XFS for ACLs):

```bash
sudo ./build_your_own_qnap.sh \
     --data  /dev/sdb,/dev/sdc,/dev/sdd \
     --raid  5 \
     --cache /dev/nvme0n1 \
     --fs    xfs \
     --force
```

The script writes `/etc/mdadm.conf`, creates `/etc/qnap_array_info.txt`, mounts via `/etc/fstab`, and logs to **/var/log/build\_qnap.log**.

---

## Script 2 – provision\_shares.sh

Adds an export with strong defaults: `root_squash`, limited CIDR, no guest access, SGID `2770` base permissions, **POSIX ACLs** (on XFS) for group/NFS-anonymous access, and UFW rules.

```text
Usage: provision_shares.sh [options]
  --path   <dir>   Absolute directory to export
  --name   <name>  Share name (defaults to basename of path)
  --proto  <list>  nfs,samba or both (default both)
  --cidr   <list>  Allowed CIDRs (default 192.168.0.0/16,10.0.0.0/8)
  --user   <user>  Restrict access; creates user if necessary
  --quota  <size>  XFS project quota (e.g. 500G)
  --force          Non‑interactive
```

Example unattended share for "media":

```bash
sudo ./provision_shares.sh \
     --path  /srv/storage/media \
     --name  media \
     --proto samba,nfs \
     --cidr  192.168.1.0/24 \
     --user  plex \
     --quota 5T \
     --force
```

The script writes **/etc/exports**, appends to `/etc/samba/smb.conf` (or uses includes), manages `/etc/projects` and `/etc/projid` for quotas, applies ACLs via `setfacl` (on XFS), reloads services, and logs to **/var/log/provision\_shares.log**.

---

## End‑to‑end Workflow

1.  **Partition** (optional) – present raw block devices to Linux.
2.  **Run build_your_own_qnap.sh** – creates `/dev/mdX` → `qnap-vg` → `qnap-data` LV → mount (use `--fs xfs` for best results).
3.  **Run provision_shares.sh** – exposes sub‑folders over NFS/Samba, setting base permissions and applying ACLs if on XFS.
4.  **Map clients** – mount NFS (`mount -t nfs`) or SMB (`net use` / Finder / Explorer) from your LAN.

---

## Security notes

- NFS exports use `root_squash`, `sync`, and CIDR filtering.
- Samba share denies guests and maps users to a dedicated POSIX group.
- Base directory permissions are `2770` (owner=rwx, group=rwx+sgid, other=---).
- **POSIX ACLs** (on XFS) are used to grant necessary access to the share group (`$GROUP`) and the NFS anonymous user (`nobody`/`nogroup`), ensuring new files/directories inherit correct permissions. This helps avoid conflicts between NFS and Samba access.
- Passwords are set via `smbpasswd` (hashed, not stored in script).
- UFW rules narrow traffic to NFS (TCP 2049) and SMB (TCP 139, 445) for the allowed subnets.
- For encrypted transport add:
    - **NFS:** `sec=krb5p` (Kerberos + privacy) on both server & clients.
    - **Samba:** `smb encrypt = desired|mandatory` per share.

---

## Troubleshooting

| Symptom                                     | Fix                                                                                                                                                                                                                            |
| :------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mdadm: Device or resource busy`            | The devices already contain a signature. Wipe with `wipefs -a /dev/sdX`.                                                                                                                                                       |
| Clients get `permission denied`             | Ensure client IP falls in `--cidr`, user belongs to share group, and correct mount options (`vers=3` for NFSv3, `vers=4` for NFSv4). Check filesystem permissions (`ls -ld <path>`) and ACLs (`getfacl <path>`) on the server. |
| Permissions work for Samba but not NFS (or vice-versa) | This often indicates an ACL issue or a non-XFS filesystem. Use `getfacl <path>` to check effective permissions. Ensure the `acl` package is installed. If not using XFS, rely on standard group permissions. |
| Samba share invisible on Windows            | Enable "SMB 1.0/CIFS Client" if using **NetBIOS** discovery (not recommended), or connect directly: `\\SERVER\share`. Ensure `nmbd` service is running.                                                                        |
| XFS Quota commands fail                     | Ensure the filesystem was mounted with `prjquota` option (check `mount` output). The script attempts to add this to `/etc/fstab` and remount, but manual intervention might be needed. Ensure `xfsprogs` is installed.        |

---

## Contributing

Pull requests welcome! Follow these steps:

1.  Fork → create branch → make changes.
2.  Run `shellcheck *.sh` – scripts must pass.
3.  Document flag additions in this README.
4.  Submit PR with a clear description.

---

## License

MIT – see **LICENSE** file.
