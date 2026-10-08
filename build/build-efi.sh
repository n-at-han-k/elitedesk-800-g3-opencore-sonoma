#!/usr/bin/env bash
# Assemble work/EFI from the fetched upstream pieces.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/work"
E="$W/EFI"
[ -d "$W/opencore" ] || { echo "run build/fetch-deps.sh first" >&2; exit 1; }

rm -rf "$E"
cp -r "$W/opencore/X64/EFI" "$E"

echo "==> pruning drivers to the three we use"
cd "$E/OC/Drivers"
for f in *; do
  case "$f" in OpenRuntime.efi|ResetNvramEntry.efi) ;; *) rm -rf "$f" ;; esac
done
cp "$W/HfsPlus.efi" .

echo "==> pruning tools to OpenShell"
cd "$E/OC/Tools"
for f in *; do [ "$f" = OpenShell.efi ] || rm -rf "$f"; done

echo "==> ACPI (machine specific, from atomsec)"
A="$W/atomsec/EFI_Minimum/OC/ACPI"
cp "$A/SSDT-AWAC-HPET-RTC.aml" "$A/SSDT-EC-USBX.aml" "$A/SSDT-PLUG.aml" "$E/OC/ACPI/"

echo "==> kexts"
K="$E/OC/Kexts"; rm -rf "$K"; mkdir -p "$K"
X="$W/kexts-extract"; rm -rf "$X"; mkdir -p "$X"
for z in "$W"/kexts/*.zip; do
  n=$(basename "$z" .zip); mkdir -p "$X/$n"; unzip -q "$z" -d "$X/$n"
done
cp -r "$X/Lilu/Lilu.kext"                      "$K/"
cp -r "$X/VirtualSMC/Kexts/VirtualSMC.kext"    "$K/"
cp -r "$X/VirtualSMC/Kexts/SMCProcessor.kext"  "$K/"
cp -r "$X/VirtualSMC/Kexts/SMCSuperIO.kext"    "$K/"
cp -r "$X/WhateverGreen/WhateverGreen.kext"    "$K/"
cp -r "$X/AppleALC/AppleALC.kext"              "$K/"
cp -r "$X/IntelMausi/IntelMausi.kext"          "$K/"
cp -r "$X/NVMeFix/NVMeFix.kext"                "$K/"
cp -r "$X/RestrictEvents/RestrictEvents.kext"  "$K/"
cp -r "$X/USBToolBox/USBToolBox.kext"          "$K/"
# USB port map for this chassis, authored by atomsec
cp -r "$W/atomsec/EFI_Minimum/OC/Kexts/UTBMap.kext" "$K/"

echo "==> config.plist"
python3 "$ROOT/build/make_config.py" --out "$E/OC/config.plist"

echo "==> validating"
"$W/opencore/Utilities/ocvalidate/ocvalidate.linux" "$E/OC/config.plist"
echo
echo "EFI built at $E"
