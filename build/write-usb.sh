#!/usr/bin/env bash
# Build the macOS Sonoma OpenCore installer USB.
# Usage: sudo ./write-usb.sh /dev/sdX        (whole disk, NOT a partition)
set -euo pipefail

W="${W:-$(cd "$(dirname "$0")/.." && pwd)/work}"
DEV=${1:-}

die(){ echo "ERROR: $*" >&2; exit 1; }

[ -n "$DEV" ] || die "no device given. Usage: $0 /dev/sdX"
[ -b "$DEV" ] || die "$DEV is not a block device"
case "$DEV" in
  *[0-9]) die "$DEV looks like a partition. Pass the whole disk, e.g. /dev/sdb" ;;
esac
# Hard refusals: the system disk and the existing encrypted data stick.
case "$DEV" in
  /dev/nvme*|/dev/sda) die "refusing to touch $DEV (system disk / existing data stick)" ;;
esac
# Refuse anything currently mounted or holding a dm/crypt mapping.
if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$DEV"
  die "$DEV has mounted partitions. Unmount first, or pick the right device."
fi
if lsblk -no TYPE "$DEV" | grep -q crypt; then
  die "$DEV contains an encrypted mapping. Refusing."
fi

SIZE=$(lsblk -bdno SIZE "$DEV")
echo "=== TARGET ==="
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,FSTYPE,LABEL "$DEV"
echo "=============="
[ "$SIZE" -ge $((4*1000*1000*1000)) ] || die "device is under 4GB"
[ "$SIZE" -le $((256*1000*1000*1000)) ] || die "device is over 256GB - that does not look like the USB stick you meant"

read -rp "ERASE ALL DATA on $DEV and write the macOS installer? Type ERASE to confirm: " ans
[ "$ans" = "ERASE" ] || die "aborted"

echo "--> wiping existing signatures"
wipefs -a "$DEV"

echo "--> creating GPT with one Microsoft-basic-data partition"
# Dortania Method 1: single FAT32 partition, type 0700 / EBD0A0A2-...
fdisk "$DEV" <<'FDISK'
g
n
1


t
EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
w
FDISK

sleep 2
partprobe "$DEV" 2>/dev/null || true
sleep 2

PART=$(lsblk -lno NAME,TYPE "$DEV" | awk '$2=="part"{print "/dev/"$1; exit}')
[ -n "$PART" ] || die "could not find the new partition"
echo "--> formatting $PART as FAT32, label OPENCORE"
mkfs.vfat -F 32 -n OPENCORE "$PART"

MNT=$(mktemp -d)
echo "--> mounting $PART at $MNT"
mount "$PART" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

echo "--> copying macOS recovery image"
mkdir -p "$MNT/com.apple.recovery.boot"
cp -v "$W/recovery/BaseSystem.dmg"       "$MNT/com.apple.recovery.boot/"
cp -v "$W/recovery/BaseSystem.chunklist" "$MNT/com.apple.recovery.boot/"

echo "--> copying OpenCore EFI"
cp -r "$W/EFI" "$MNT/EFI"

sync
echo "--> contents:"
find "$MNT" -maxdepth 3 -not -path '*/Kexts/*/*' | sed "s|$MNT|USB|"
df -h "$MNT" | tail -1
echo
echo "DONE. Unmounting."
