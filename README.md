# macOS Sonoma on HP EliteDesk 800 G3 DM (Skylake, Intel HD 530)

A reproducible OpenCore build for the HP EliteDesk 800 G3 Desktop Mini, assembled
**from Linux** — no existing Mac required.

**Status:** installer boots and proceeds to install on the hardware below. Hardware
details were read back from an OpenCore DEBUG log on the machine itself, not from the
spec sheet.

Target hardware:

| | |
|---|---|
| Model | HP EliteDesk 800 G3 DM |
| CPU | Intel Core i5-6500T (Skylake, 35 W) |
| iGPU | Intel HD Graphics 530 |
| Chipset | Q270 |
| Ethernet | Intel I219-LM |
| Audio | Conexant CX20632 |
| macOS | Sonoma 14 |
| Bootloader | OpenCore 1.0.8 |
| SMBIOS | `Macmini8,1` |

## The one thing that makes this work

**Skylake's iGPU drivers were removed from macOS after Monterey.** Left alone, HD 530
reports ~7 MB of VRAM with no acceleration, and that's where most attempts at this
machine stall. The fix is to spoof it as a Kaby Lake HD 630:

```
PciRoot(0x0)/Pci(0x2,0x0)
    AAPL,ig-platform-id  00001259      # 0x59120000, KBL desktop framebuffer
    device-id            12590000      # 0x5912
```

Install with `-igfxvesa` in `boot-args` (unaccelerated VESA — slow but it gets through
the installer), then remove it once you're on the desktop.

The second non-obvious requirement is `SSDT-AWAC-HPET-RTC.aml`. HP's RTC/HPET ACPI
declaration will reboot or hang the installer early without it.

## Build it

```sh
./build/fetch-deps.sh          # OpenCore, kexts, HfsPlus, machine-specific ACPI
# then download the macOS recovery image (command is printed by fetch-deps.sh)

./build/build-efi.sh           # assembles work/EFI and runs ocvalidate
sudo ./build/write-usb.sh /dev/sdX    # partitions + writes the installer USB
```

### SMBIOS

**No serial numbers are committed to this repo**, deliberately — a shared Mac serial
breaks Apple services for everyone using it. Generate your own:

```sh
work/opencore/Utilities/macserial/macserial.linux -m Macmini8,1 -n 1
export OC_SERIAL=... OC_MLB=... OC_ROM=$(openssl rand -hex 6)
./build/build-efi.sh
```

Check the serial reports as *unrecognised* at <https://checkcoverage.apple.com> before
signing into anything. `config/config.plist` is a reference copy with the identifiers
replaced by `CHANGEME-*`.

### What `write-usb.sh` will not do

It refuses `/dev/nvme*` and `/dev/sda`, refuses partitions (whole disk only), refuses
mounted or LUKS-mapped devices, refuses anything under 4 GB or over 256 GB, and requires
you to type `ERASE`. Check the target anyway.

## Configuration rationale

| Setting | Value | Why |
|---|---|---|
| SMBIOS | `Macmini8,1` | Coffee Lake Mac mini, still Apple-supported in Sonoma. iMac17,x/18,x are dropped. |
| `device-id` | `12590000` | Spoofs HD 530 → HD 630; see above. |
| `layout-id` | `1c000000` (28) | Conexant CX20632 analog audio. |
| `framebuffer-con0/1/2-alldata` | — | Port layout for this chassis' DisplayPorts. |
| `SSDT-AWAC-HPET-RTC` | enabled | HP RTC/HPET fix. Required. |
| `SSDT-EC-USBX` | enabled | Embedded controller + USB power, Skylake desktop. |
| `SSDT-PLUG` | enabled | Native CPU power management (XCPM plugin-type 1). |
| `AppleCpuPmCfgLock`, `AppleXcpmCfgLock` | true | HP BIOS exposes no CFG-Lock toggle. Confirmed necessary: OpenCore reports `OCCPU: EIST CFG Lock 1` on this board. |
| `DisableIoMapper` | true | VT-d is turned off in BIOS. |
| `DisableRtcChecksum` | true | **Required on this machine.** Without it macOS corrupts the CMOS primary checksum and HP POSTs `system time is invalid` on every subsequent boot. |
| `LapicKernelPanic` | true | HP firmware raises spurious LAPIC interrupts. |
| `XhciPortLimit` | **false** | Broken on 11.3+ (boot loops). Unnecessary — `UTBMap` maps the ports. |
| `SecureBootModel` | `Disabled` | Required with a spoofed iGPU. |

## BIOS setup (F10 at boot)

Reset BIOS to defaults first, then:

- **Advanced → Boot Options**: Fast Boot **off**; USB Storage Boot **on**;
  put the USB first in UEFI boot order (or press F9 to pick it).
- **Advanced → Secure Boot Configuration**: *Legacy Support Disable and Secure Boot Disable*.
- **Advanced → System Options**: Virtualization Technology (VTx) **on**;
  **VT-d off**; M.2 SSD **on** (if NVMe); M.2 WLAN/BT **on**;
  Allow PCIe/PCI SERR# Interrupt **on**.
- **Advanced → Built-in Device Options**: Wake on LAN **off**;
  **Video memory size → 64 MB or more**; LAN/WLAN Auto Switching **off**;
  Wake on USB **off**.

Save and exit.

## Install

1. Boot the USB → OpenCore picker → choose **macOS Base System** (or *Install macOS*).
2. Expect a wall of verbose text. It will be slow — that's `-igfxvesa` doing software
   rendering, not a fault.
3. In **Disk Utility**: View → *Show All Devices*, select the whole target SSD,
   Erase as **APFS** / **GUID Partition Map**.
4. Install macOS. It reboots several times — **keep booting from the USB** each time
   until you land on the desktop.

## After install

1. Mount the internal disk's EFI partition and copy this `EFI` folder onto it, so the
   machine boots without the USB. Copy/paste the whole folder; do not merge.
2. Reset NVRAM once from the OpenCore picker, then remove `-igfxvesa` from `boot-args`
   to get graphics acceleration.
3. **Generate your own SMBIOS** if you haven't already — see the SMBIOS section above.
   Check the serial reports as *unrecognised* at checkcoverage.apple.com before signing
   into any Apple service.
4. Re-map USB with USBToolBox/USBMap on your own machine if any port misbehaves —
   `UTBMap.kext` here came from another unit of this model.

## After install: postinstall.sh

Run this **on the EliteDesk**, once macOS is up. One file, no dependencies beyond what
macOS ships:

```sh
curl -fsSLO https://raw.githubusercontent.com/n-at-han-k/elitedesk-800-g3-opencore-sonoma/main/postinstall.sh
chmod +x postinstall.sh
./postinstall.sh status          # read-only report - start here
```

| Command | What it does |
|---|---|
| `status` | Reports iGPU acceleration (Metal present? VRAM reading ~7 MB?), current `boot-args`, audio devices, ethernet, SIP, serial, sleep settings, and whether OpenCore is on the internal disk. Changes nothing. |
| `install-efi` | Finds the internal disk's EFI partition, mounts it, copies the `EFI` folder from the USB, and verifies the copy with `diff -r`. Any existing `EFI` is moved aside, not deleted. |
| `enable-gpu` | Strips `-igfxvesa` from `boot-args` so the iGPU accelerates. |
| `smbios` | Generates a fresh `Macmini8,1` serial/MLB/UUID/ROM with `macserial` and writes them in. |
| `validate` | Runs `ocvalidate` against the internal `config.plist`. |

Flags: `--from <path>` to point `install-efi` at a specific EFI folder, `--disk diskN`
to skip disk auto-detection, `--debug` to show how the disk and ESP were resolved,
`--yes` to skip prompts, `--help` anywhere.

Disk detection resolves the volume at `/` through its APFS physical store to the parent
whole disk, then finds that disk's EFI partition — it does not assume `disk0s1`. Each
lookup tries the plist keypath first and falls back to parsing `diskutil`'s plain-text
output, because the key names and labels differ across macOS versions. If it still gets
it wrong, `--debug` shows each step and `--disk diskN` overrides it.

Every mutating command backs up `config.plist` to `EFI/OC/config-backups/` first and
prints the exact command to roll back. `smbios` and `validate` download `macserial` and
`ocvalidate` from the official OpenCorePkg release at run time; nothing else needs network.

**Keep the USB.** It stays a working rescue disk — if the machine won't boot after any of
this, boot the USB and pick the internal volume from the picker.

Order that makes sense: `status` → `install-efi` → `smbios` → `enable-gpu` → `validate`
→ reboot without the USB. Reset NVRAM from the OpenCore picker after `smbios` or
`enable-gpu`, since `boot-args` and the serial are read from NVRAM.

## Gotcha: the picker hides macOS Recovery

OpenCore flags **macOS Recovery entries as auxiliary**. With `Misc/Boot/HideAuxiliary`
set to `true`, the picker will show only your other OS (Windows, say) and happily boot
it — the recovery installer is there, just hidden. Press **Space** at the picker to
reveal it, or leave `HideAuxiliary` as `false` (what this config does).

The `OCB: Policy filter mode 0 - no blessed folder found` lines during scan are normal
noise for volumes without a bootloader, not the cause.

Be aware when debugging this from a log: OpenCore logs `OCB: Not adding hidden auxiliary
entry ...` for **tools and system entries** (OpenShell, Reset NVRAM) but logs *nothing*
for a filesystem recovery entry it hides. A DEBUG log with no mention of `recovery`,
`dmg` or `BaseSystem` anywhere is therefore consistent with `HideAuxiliary` being the
cause, not evidence against it. `HideAuxiliary` is documented in `Docs/Configuration.tex`
as covering "Entry is macOS recovery".

## Known-unresolved on this hardware

- If HP POSTs **`system time is invalid`** after a macOS boot, `DisableRtcChecksum`
  is not set. It is set in this config. If it recurs even so, macOS is writing to CMOS
  outside `0x58`-`0x59`; add [RTCMemoryFixup](https://github.com/acidanthera/RTCMemoryFixup)
  and populate the `rtc-blacklist` NVRAM variable (already present, empty) with the
  offending offsets.
- **Sleep/wake** does not work (reported by every build of this model).
- **Shutdown may not fully power off** (fan keeps spinning) — HP's ACPI.
- Some people need to **unplug/replug DisplayPort once** after boot to get a signal.
  If so, adjust the `framebuffer-conX-*` entries per the WhateverGreen Intel HD FAQ.
- `AppleALC` layout 28 is for Conexant CX20632; if audio is silent, try `alcid=` values
  from the AppleALC supported-codecs list.
- Intel 8265 WiFi (if fitted) needs `AirportItlwm.kext` built for Sonoma, plus
  `IntelBluetoothFirmware` + `IntelBTPatcher` + `BlueToolFixup` — not included here.

## Credits

This is an assembly of other people's work, not original research:

- [**atomsec/HP-Elitedesk-800-G3-DM-EFI**](https://github.com/atomsec/HP-Elitedesk-800-G3-DM-EFI)
  — the same model with **HD 530 on Sonoma 14.7.6 and working acceleration**. The
  framebuffer properties, the `SSDT-AWAC-HPET-RTC` fix and `UTBMap.kext` all come from
  here. `fetch-deps.sh` pulls these from source rather than vendoring them.
- [**Dortania OpenCore Install Guide**](https://dortania.github.io/OpenCore-Install-Guide/)
  — the Linux installer method, Skylake desktop config and kext list.
- [**CloverLeafBG/HP-EliteDesk-800-G3-Mini-OC-Hackintosh**](https://github.com/CloverLeafBG/HP-EliteDesk-800-G3-Mini-OC-Hackintosh)
  — same model, HD 630, Sonoma 14.5. Corroborates `Macmini8,1` and the audio layout.
- [**mouazqureshi/OpenCore-Hackintosh-HP-EliteDesk-800-G3**](https://github.com/mouazqureshi/OpenCore-Hackintosh-HP-EliteDesk-800-G3)
  — the BIOS settings list.
- [olarila.com/topic/43033](https://olarila.com/topic/43033-new-to-hackintosh-hp-800g3-mini/)
  — same machine *and* same CPU (i5-6500 / HD 530). Source of the `-igfxvesa` install
  trick and the RTC-patch requirement.
- [forum.amd-osx.com/threads/6056](https://forum.amd-osx.com/threads/need-help-with-hp-elitedesk-800-g3.6056/)
  — 800 G3 DM 35W on Skylake; confirms the fake-ID requirement the hard way.
- [acidanthera](https://github.com/acidanthera) for OpenCore and essentially every kext.

No Apple software is distributed here. `macrecovery.py` downloads the recovery image
from Apple directly.
