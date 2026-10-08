#!/usr/bin/env bash
# Fetch everything the EFI is assembled from. Nothing here is vendored into git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/work"
mkdir -p "$W/kexts" "$W/recovery"
cd "$W"

OC_VER=${OC_VER:-1.0.8}
OC_BUILD=${OC_BUILD:-DEBUG}     # DEBUG while bringing the machine up, RELEASE after

echo "==> OpenCorePkg $OC_VER-$OC_BUILD"
curl -fsSL -o "OpenCore.zip" \
  "https://github.com/acidanthera/OpenCorePkg/releases/download/${OC_VER}/OpenCore-${OC_VER}-${OC_BUILD}.zip"
rm -rf opencore && mkdir opencore && unzip -q OpenCore.zip -d opencore

echo "==> acidanthera kexts (latest releases)"
for repo in Lilu VirtualSMC WhateverGreen AppleALC IntelMausi RestrictEvents NVMeFix; do
  url=$(curl -fsSL "https://api.github.com/repos/acidanthera/$repo/releases/latest" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next(a['browser_download_url'] for a in d['assets']
           if a['name'].endswith('.zip') and 'RELEASE' in a['name'].upper()))")
  echo "    $repo"
  curl -fsSL -o "kexts/$repo.zip" "$url"
done

echo "==> USBToolBox kext"
url=$(curl -fsSL "https://api.github.com/repos/USBToolBox/kext/releases/latest" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next(a['browser_download_url'] for a in d['assets']
           if 'RELEASE' in a['name'] and a['name'].endswith('.zip')))")
curl -fsSL -o kexts/USBToolBox.zip "$url"

echo "==> HfsPlus.efi (OcBinaryData)"
curl -fsSL -o HfsPlus.efi \
  https://raw.githubusercontent.com/acidanthera/OcBinaryData/master/Drivers/HfsPlus.efi

# Machine-specific ACPI + USB port map. Authored by atomsec for this exact model;
# not vendored here, pulled from source so attribution stays intact.
echo "==> machine-specific ACPI + UTBMap (atomsec/HP-Elitedesk-800-G3-DM-EFI)"
curl -fsSL -o atomsec.tar.gz \
  https://github.com/atomsec/HP-Elitedesk-800-G3-DM-EFI/archive/refs/heads/main.tar.gz
rm -rf atomsec && mkdir atomsec && tar xzf atomsec.tar.gz -C atomsec --strip-components=1

echo
echo "==> macOS recovery image"
echo "    Run this to download Sonoma (~750MB) into work/recovery/:"
echo
echo "    python3 $W/opencore/Utilities/macrecovery/macrecovery.py \\"
echo "        -b Mac-827FAC58A8FDFA22 -m 00000000000000000 \\"
echo "        -o $W/recovery download"
echo
echo "Done. Next: build/build-efi.sh"
