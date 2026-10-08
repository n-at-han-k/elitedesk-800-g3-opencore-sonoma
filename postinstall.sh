#!/bin/bash
# Post-install helper for HP EliteDesk 800 G3 DM + macOS Sonoma.
# Run this ON THE MAC once macOS is installed and you've reached the desktop.
#
#   ./postinstall.sh status        # read-only health report. Start here.
#   ./postinstall.sh install-efi   # copy the EFI from the USB to the internal disk
#   ./postinstall.sh enable-gpu    # drop -igfxvesa so the iGPU accelerates
#   ./postinstall.sh smbios        # generate a fresh Macmini8,1 serial/MLB/UUID/ROM
#   ./postinstall.sh validate      # ocvalidate the internal EFI's config.plist
#
# Flags: --from <path>  source EFI folder for install-efi
#        --disk diskN   skip disk auto-detection (see: diskutil list)
#        --debug        show how the disk/ESP was resolved
#        --yes          skip confirmation prompts
#
# Mutating commands back up config.plist first and print how to roll back.
# Your USB remains a working rescue disk throughout: if the machine stops booting,
# boot the USB and pick the internal volume.

set -euo pipefail

SRC_EFI=""            # --from <path to an EFI folder>
ASSUME_YES=0          # --yes
FORCE_DISK=""         # --disk diskN   (skip auto-detection)
DEBUG=0               # --debug
OC_VER="1.0.8"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  x %s\033[0m\n' "$*"; }
good() { printf '\033[32m  = %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Print the header comment block (everything from line 2 up to the first non-comment).
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "$0"; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s ' "$1 [y/N]"
  read -r a || true
  case "$a" in y|Y|yes|YES) return 0 ;; *) die "aborted" ;; esac
}

# ---------------------------------------------------------------- disk helpers

# diskutil/plutil vary across macOS versions, so read a value by plist keypath and
# fall back to parsing the plain-text output. plutil -extract needs "-o -" to write
# to stdout; without it the call fails and yields junk like "<stdin>".
#   dval <device> <PlainTextLabel> <plistKeyPath>
dval() {
  local dev="$1" label="$2" kp="$3" v=""
  v=$(diskutil info -plist "$dev" 2>/dev/null \
      | plutil -extract "$kp" raw -o - - 2>/dev/null) || v=""
  case "$v" in ""|"<stdin>"|*"could not extract"*) v="" ;; esac
  if [ -z "$v" ]; then
    v=$(diskutil info "$dev" 2>/dev/null \
        | sed -n "s/^ *${label}[^:]*: *//p" | head -1 | sed 's/ *$//')
  fi
  printf '%s' "$v"
}

dbg() { [ "$DEBUG" = 1 ] && printf '\033[90m  . %s\033[0m\n' "$*" >&2 || true; }

# Whole disk holding the running system, resolving APFS containers.
# An APFS volume's own ParentWholeDisk is the *synthesised* disk, not the real one,
# so the physical store has to be resolved first.
boot_whole_disk() {
  [ -n "$FORCE_DISK" ] && { printf '%s' "$FORCE_DISK"; return 0; }
  local vol store whole
  vol=$(df / 2>/dev/null | awk 'NR==2{print $1}'); vol=${vol#/dev/}
  [ -n "$vol" ] || vol=$(dval / "Device Identifier" DeviceIdentifier)
  dbg "volume at /        = ${vol:-<none>}"
  [ -n "$vol" ] || die "could not identify the volume mounted at / (try --disk diskN)"

  store=$(dval "$vol" "APFS Physical Store" APFSPhysicalStores.0.DeviceIdentifier)
  dbg "APFS physical store = ${store:-<none>}"
  [ -n "$store" ] || store="$vol"

  whole=$(dval "$store" "Part of Whole" ParentWholeDisk)
  dbg "parent whole disk   = ${whole:-<none>}"
  case "$whole" in
    disk[0-9]*) ;;
    *) die "could not resolve the physical disk behind / (got '${whole:-empty}' from '$store').
       Run with --debug to see the steps, or pass --disk diskN explicitly.
       'diskutil list' will show which disk holds your macOS volume." ;;
  esac
  printf '%s' "$whole"
}

# The EFI System Partition on that disk.
esp_of() {
  local whole="$1" esp="" i cand content
  # Primary: the partition table listing names the ESP in column 2.
  esp=$(diskutil list "$whole" 2>/dev/null \
        | awk '$2=="EFI" {print $NF; exit}')
  case "$esp" in disk[0-9]*) dbg "ESP via diskutil list = $esp"; printf '%s' "$esp"; return 0 ;; esac
  # Fallback: probe each partition's content type.
  for i in 1 2 3 4 5 6 7 8 9; do
    cand="${whole}s${i}"
    diskutil info "$cand" >/dev/null 2>&1 || continue
    content=$(dval "$cand" "Content" Content)
    dbg "probe $cand content = ${content:-<none>}"
    [ "$content" = "EFI" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

ESP_MNT=""
ESP_WAS_MOUNTED=0
mount_esp() {
  local whole esp mp
  whole=$(boot_whole_disk)
  esp=$(esp_of "$whole") || die "no EFI partition found on /dev/$whole.
       Check 'diskutil list $whole' shows an EFI partition; --debug shows the probe."
  mp=$(dval "$esp" "Mount Point" MountPoint)
  if [ -n "$mp" ]; then
    ESP_MNT="$mp"; ESP_WAS_MOUNTED=1
  else
    say "Mounting the internal EFI partition ($esp) - this needs sudo"
    sudo diskutil mount "$esp" >/dev/null || die "could not mount $esp"
    mp=$(dval "$esp" "Mount Point" MountPoint)
    [ -n "$mp" ] || die "$esp mounted but has no mount point"
    ESP_MNT="$mp"
  fi
  info "internal ESP: $esp at $ESP_MNT"
}
unmount_esp() {
  [ -n "$ESP_MNT" ] || return 0
  [ "$ESP_WAS_MOUNTED" = 1 ] && return 0
  sudo diskutil unmount "$ESP_MNT" >/dev/null 2>&1 || true
}

internal_config() {
  [ -f "$ESP_MNT/EFI/OC/config.plist" ] \
    || die "no EFI/OC/config.plist on the internal ESP. Run 'install-efi' first."
  printf '%s' "$ESP_MNT/EFI/OC/config.plist"
}

backup_config() {
  local cfg="$1" stamp dest
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$ESP_MNT/EFI/OC/config-backups"
  sudo mkdir -p "$dest"
  sudo cp "$cfg" "$dest/config-$stamp.plist"
  good "backed up to EFI/OC/config-backups/config-$stamp.plist"
  info "roll back with:  sudo cp '$dest/config-$stamp.plist' '$cfg'"
}

# Fetch macserial + ocvalidate from the official OpenCorePkg release.
OC_TOOLS=""
fetch_oc_tools() {
  [ -n "$OC_TOOLS" ] && return 0
  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/acidanthera/OpenCorePkg/releases/download/${OC_VER}/OpenCore-${OC_VER}-RELEASE.zip"
  say "Fetching macserial + ocvalidate from OpenCorePkg ${OC_VER}"
  info "$url"
  curl -fsSL -o "$tmp/oc.zip" "$url" || die "download failed (no network?)"
  unzip -q "$tmp/oc.zip" -d "$tmp/oc"
  OC_TOOLS="$tmp/oc/Utilities"
  chmod +x "$OC_TOOLS/macserial/macserial" "$OC_TOOLS/ocvalidate/ocvalidate" 2>/dev/null || true
}

BOOT_GUID="7C436110-AB2A-4BBB-A880-FE41995C9F82"

# ---------------------------------------------------------------------- status

cmd_status() {
  # A read-only report must degrade gracefully rather than abort on the first
  # tool that is missing or exits non-zero, so errexit/pipefail are off here.
  set +e +o pipefail
  say "== Machine"
  info "$(sysctl -n machdep.cpu.brand_string)"
  info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  info "SMBIOS model: $(sysctl -n hw.model)"

  say "== Graphics (the thing most likely to be wrong)"
  local gfx vram metal
  gfx=$(system_profiler SPDisplaysDataType 2>/dev/null || true)
  vram=$(printf '%s' "$gfx" | awk -F': ' '/VRAM|Total Number of Cores/ {print $2; exit}')
  metal=$(printf '%s' "$gfx" | awk -F': ' '/Metal/ {print $2; exit}')
  printf '%s' "$gfx" | sed -n 's/^ *Chipset Model: /  chipset: /p'
  [ -n "$vram" ]  && info "vram:    $vram"
  [ -n "$metal" ] && info "metal:   $metal"
  if printf '%s' "$gfx" | grep -q 'Metal Support'; then
    good "Metal is present - the iGPU is accelerated"
  else
    bad "no Metal support - iGPU is NOT accelerated"
    info "if you still have -igfxvesa set, run: $0 enable-gpu"
  fi
  if printf '%s' "$gfx" | grep -qiE '7 MB|VRAM.*: 7'; then
    bad "VRAM reads ~7MB - classic unaccelerated Skylake symptom"
  fi

  say "== Current boot-args"
  local ba
  ba=$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//') || ba=""
  if [ -n "$ba" ]; then
    info "$ba"
    case "$ba" in *-igfxvesa*) warn "-igfxvesa is active: software rendering, expect it to feel slow" ;; esac
  else
    info "(none set)"
  fi

  say "== Audio"
  if system_profiler SPAudioDataType 2>/dev/null | grep -q 'Devices:'; then
    system_profiler SPAudioDataType 2>/dev/null | sed -n 's/^ *\([A-Za-z].*\):$/  \1/p' | head -8
  else
    bad "no audio devices - check the AppleALC layout-id (28 for CX20632)"
  fi

  say "== Network"
  have networksetup && networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port/{p=$3" "$4} /Device/{print "  "p" -> "$2}' | head -6
  if ifconfig en0 >/dev/null 2>&1 && ifconfig en0 | grep -q 'status: active'; then
    good "en0 is up (IntelMausi working)"
  else
    warn "en0 is not active - plug in ethernet or check IntelMausi"
  fi

  say "== Security / SMBIOS"
  info "SIP: $(csrutil status 2>/dev/null | sed 's/^System Integrity Protection status: //' || echo unknown)"
  local serial
  serial=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}')
  info "serial: ${serial:-unknown}"
  if [ "$serial" = "CHANGEME-SERIAL" ] || [ -z "$serial" ]; then
    bad "placeholder or missing serial - run: $0 smbios"
  else
    warn "check this serial reads as UNRECOGNISED at https://checkcoverage.apple.com"
    info "if Apple recognises it, someone else owns it - run '$0 smbios' for a new one"
  fi

  say "== Sleep (known broken on this hardware)"
  have pmset && info "hibernatemode: $(pmset -g 2>/dev/null | awk '/hibernatemode/{print $2}')"
  info "Sleep/wake does not work on the 800 G3. Consider: sudo pmset -a sleep 0 disablesleep 1"

  say "== Boot disk"
  local whole esp
  whole=$(boot_whole_disk); esp=$(esp_of "$whole" || true)
  info "system disk: /dev/$whole   ESP: ${esp:-none found}"
  if [ -n "${esp:-}" ]; then
    local mp; mp=$(dval "$esp" "Mount Point" MountPoint)
    if [ -n "$mp" ] && [ -d "$mp/EFI/OC" ]; then
      good "OpenCore is installed on the internal disk"
    else
      warn "cannot tell if OpenCore is on the internal ESP (not mounted)"
      info "run '$0 install-efi' if you are still booting from the USB"
    fi
  fi
}

# ----------------------------------------------------------------- install-efi

cmd_install_efi() {
  local src="$SRC_EFI"
  if [ -z "$src" ]; then
    for c in /Volumes/OPENCORE/EFI /Volumes/EFI/EFI; do
      [ -d "$c/OC" ] && { src="$c"; break; }
    done
  fi
  [ -n "$src" ] || die "no source EFI found. Plug in the installer USB, or pass --from <path>"
  [ -d "$src/OC" ] && [ -f "$src/OC/config.plist" ] || die "$src does not look like an EFI folder"

  say "Installing OpenCore to the internal disk"
  info "source: $src"
  mount_esp
  trap unmount_esp EXIT

  if [ -d "$ESP_MNT/EFI" ]; then
    warn "$ESP_MNT/EFI already exists and will be REPLACED"
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    confirm "Replace it? (the old one is kept as EFI-backup-$stamp)"
    sudo mv "$ESP_MNT/EFI" "$ESP_MNT/EFI-backup-$stamp"
    good "old EFI kept as EFI-backup-$stamp"
  else
    confirm "Copy $src -> $ESP_MNT/EFI ?"
  fi

  # -R not -a: the ESP is FAT32 and cannot hold the extended attributes.
  sudo cp -R "$src" "$ESP_MNT/EFI"
  sync
  good "copied"

  info "verifying against the source"
  if sudo diff -r "$src" "$ESP_MNT/EFI" >/dev/null 2>&1; then
    good "internal EFI is identical to the source"
  else
    warn "differences found - listing:"
    sudo diff -r "$src" "$ESP_MNT/EFI" 2>&1 | head -20
  fi

  say "Next"
  info "1. $0 smbios        (give this machine its own serial)"
  info "2. $0 enable-gpu    (drop -igfxvesa)"
  info "3. reboot, remove the USB, and let the internal disk boot"
  info "Keep the USB. If the machine will not boot, boot the USB and pick the internal volume."
}

# ------------------------------------------------------------------ enable-gpu

cmd_enable_gpu() {
  mount_esp; trap unmount_esp EXIT
  local cfg ba new
  cfg=$(internal_config)
  ba=$(plutil -extract "NVRAM.Add.$BOOT_GUID.boot-args" raw "$cfg" 2>/dev/null || true)
  say "Removing -igfxvesa from boot-args"
  info "current: ${ba:-(empty)}"
  case "$ba" in
    *-igfxvesa*) ;;
    *) good "-igfxvesa is not set; nothing to do"; return 0 ;;
  esac
  new=$(printf '%s' "$ba" | sed 's/-igfxvesa//g' | tr -s ' ' | sed 's/^ //; s/ $//')
  info "new:     ${new:-(empty)}"
  confirm "Apply?"
  backup_config "$cfg"
  sudo plutil -replace "NVRAM.Add.$BOOT_GUID.boot-args" -string "$new" "$cfg"
  sudo plutil -convert xml1 "$cfg"
  good "config.plist updated"
  warn "boot-args live in NVRAM. Reset NVRAM from the OpenCore picker on next boot,"
  warn "or run: sudo nvram -d boot-args"
  say "If you get no display after this"
  info "unplug and replug the DisplayPort cable once - known quirk on this model."
  info "If that is needed every boot, the framebuffer-conX-* properties need adjusting;"
  info "see the WhateverGreen Intel HD FAQ linked in the README."
}

# ---------------------------------------------------------------------- smbios

cmd_smbios() {
  mount_esp; trap unmount_esp EXIT
  local cfg; cfg=$(internal_config)
  fetch_oc_tools
  say "Generating a fresh Macmini8,1 identity"
  local pair serial mlb uuid rom
  pair=$("$OC_TOOLS/macserial/macserial" -m Macmini8,1 -n 1 | head -1)
  serial=$(printf '%s' "$pair" | awk -F' *\\| *' '{print $1}')
  mlb=$(printf '%s' "$pair"    | awk -F' *\\| *' '{print $2}')
  uuid=$(uuidgen)
  rom=$(openssl rand -hex 6)
  [ -n "$serial" ] && [ -n "$mlb" ] || die "macserial produced nothing usable"
  info "serial: $serial"
  info "MLB:    $mlb"
  info "UUID:   $uuid"
  info "ROM:    $rom"
  echo
  warn "Before trusting this: check $serial reads as UNRECOGNISED at"
  warn "https://checkcoverage.apple.com - if Apple knows it, re-run this command."
  confirm "Write these into the internal config.plist?"
  backup_config "$cfg"
  sudo plutil -replace PlatformInfo.Generic.SystemSerialNumber -string "$serial" "$cfg"
  sudo plutil -replace PlatformInfo.Generic.MLB               -string "$mlb"    "$cfg"
  sudo plutil -replace PlatformInfo.Generic.SystemUUID        -string "$uuid"   "$cfg"
  sudo plutil -replace PlatformInfo.Generic.ROM \
       -data "$(printf '%s' "$rom" | xxd -r -p | base64)" "$cfg"
  sudo plutil -convert xml1 "$cfg"
  good "config.plist updated"
  info "Reset NVRAM from the OpenCore picker, then reboot for this to take effect."
  info "Sign out of iCloud/iMessage BEFORE changing a serial you have already used."
}

# -------------------------------------------------------------------- validate

cmd_validate() {
  mount_esp; trap unmount_esp EXIT
  local cfg; cfg=$(internal_config)
  fetch_oc_tools
  say "Validating the internal config.plist"
  "$OC_TOOLS/ocvalidate/ocvalidate" "$cfg"
}

# ------------------------------------------------------------------------ main

CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) SRC_EFI="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --disk) FORCE_DISK="${2:-}"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    status|install-efi|enable-gpu|smbios|validate) CMD="$1"; shift ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done
[ -n "$CMD" ] || { usage; exit 1; }

# Everything below touches the running Mac, so refuse elsewhere. Checked here
# rather than at the top so --help works on any machine.
[ "$(uname -s)" = "Darwin" ] \
  || die "this script runs on macOS, on the EliteDesk itself (uname says $(uname -s))."

case "$CMD" in
  status)      cmd_status ;;
  install-efi) cmd_install_efi ;;
  enable-gpu)  cmd_enable_gpu ;;
  smbios)      cmd_smbios ;;
  validate)    cmd_validate ;;
esac
