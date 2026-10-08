#!/usr/bin/env python3
"""Build config.plist for HP EliteDesk 800 G3 DM (Skylake / Intel HD 530) -> macOS Sonoma.

Base: OpenCore 1.0.8 Sample.plist. Hardware values from
atomsec/HP-Elitedesk-800-G3-DM-EFI (same model, i7-6700T / HD 530,
Sonoma 14.7.6, iGPU acceleration working).

SMBIOS identifiers are NOT committed. Generate your own:

    work/opencore/Utilities/macserial/macserial.linux -m Macmini8,1 -n 1

then either export them:

    export OC_SERIAL=... OC_MLB=... OC_UUID=... OC_ROM=aabbccddeeff

or pass --serial/--mlb/--uuid/--rom. Without them this writes obvious
placeholders and refuses to pretend they are usable.
"""
import argparse, os, plistlib, sys, uuid as _uuid

HERE   = os.path.dirname(os.path.abspath(__file__))
ROOT   = os.path.dirname(HERE)
SAMPLE = os.environ.get("OC_SAMPLE", f"{ROOT}/work/opencore/Docs/Sample.plist")

ap = argparse.ArgumentParser()
ap.add_argument("--out", default=f"{ROOT}/work/EFI/OC/config.plist")
ap.add_argument("--sample", default=SAMPLE)
ap.add_argument("--serial", default=os.environ.get("OC_SERIAL"))
ap.add_argument("--mlb",    default=os.environ.get("OC_MLB"))
ap.add_argument("--uuid",   default=os.environ.get("OC_UUID"))
ap.add_argument("--rom",    default=os.environ.get("OC_ROM"))
ap.add_argument("--boot-args", default=os.environ.get(
    "OC_BOOT_ARGS", "-v debug=0x100 keepsyms=1 -igfxvesa"))
a = ap.parse_args()

SAMPLE = a.sample
OUT    = a.out

if not all((a.serial, a.mlb)):
    print("WARNING: no SMBIOS supplied - writing PLACEHOLDER serial/MLB.\n"
          "         This config will NOT work with Apple services until you\n"
          "         generate real ones with macserial. See the docstring.",
          file=sys.stderr)

SMBIOS = dict(
    SystemProductName  = "Macmini8,1",
    SystemSerialNumber = a.serial or "CHANGEME-SERIAL",
    MLB                = a.mlb    or "CHANGEME-MLB",
    SystemUUID         = a.uuid   or str(_uuid.uuid4()).upper(),
    ROM                = bytes.fromhex(a.rom) if a.rom else os.urandom(6),
)

BOOT_ARGS = a.boot_args

d = plistlib.load(open(SAMPLE, "rb"))

# ---------------- ACPI ----------------
d["ACPI"]["Add"] = [
    {"Comment": "HP RTC/HPET/AWAC range fix (machine specific)",
     "Enabled": True, "Path": "SSDT-AWAC-HPET-RTC.aml"},
    {"Comment": "Embedded controller + USBX power (Skylake desktop)",
     "Enabled": True, "Path": "SSDT-EC-USBX.aml"},
    {"Comment": "Native CPU power management (XCPM plugin-type 1)",
     "Enabled": True, "Path": "SSDT-PLUG.aml"},
]
d["ACPI"]["Delete"] = []
d["ACPI"]["Patch"]  = []

# ---------------- Booter ----------------
bq = d["Booter"]["Quirks"]
for k in ("AvoidRuntimeDefrag", "EnableSafeModeSlide", "EnableWriteUnprotector",
          "ProvideCustomSlide", "SetupVirtualMap"):
    bq[k] = True
for k in ("DevirtualiseMmio", "DisableSingleUser", "DisableVariableWrite",
          "ForceBooterSignature", "ProtectMemoryRegions", "ProtectSecureBoot",
          "ProtectUefiServices", "ProvideMaxSlide", "RebuildAppleMemoryMap",
          "SignalAppleOS", "SyncRuntimePermissions"):
    if k in bq:
        bq[k] = False if isinstance(bq[k], bool) else bq[k]
bq["ProvideMaxSlide"] = 0
bq["ResizeAppleGpuBars"] = -1

# ---------------- DeviceProperties ----------------
h = bytes.fromhex
d["DeviceProperties"]["Add"] = {
    # Conexant CX20632 analog audio
    "PciRoot(0x0)/Pci(0x1F,0x3)": {"layout-id": h("1c000000")},
    # Intel HD 530 (Skylake) spoofed to Kaby Lake HD 630 0x5912 so Sonoma drivers bind
    "PciRoot(0x0)/Pci(0x2,0x0)": {
        "AAPL,ig-platform-id":        h("00001259"),
        "device-id":                  h("12590000"),
        "AAPL,GfxYTile":              h("01000000"),
        "framebuffer-patch-enable":   h("01000000"),
        # con0: DisplayPort  (index 1, busid 0x05, pipe 0x09, type 0x00000800, flags 0x187)
        "framebuffer-con0-enable":    h("01000000"),
        "framebuffer-con0-alldata":   h("010509000008000087010000"),
        # con1: index 2, busid 0x04, pipe 0x0a, type 0x00000400
        "framebuffer-con1-enable":    h("01000000"),
        "framebuffer-con1-alldata":   h("02040a000004000087010000"),
        # con2: index 3, busid 0x06, pipe 0x0a, type 0x00000400
        "framebuffer-con2-enable":    h("01000000"),
        "framebuffer-con2-alldata":   h("03060a000004000087010000"),
    },
}
d["DeviceProperties"]["Delete"] = {}

# ---------------- Kernel ----------------
KEXTS = [
    ("Lilu.kext",           "Contents/MacOS/Lilu"),
    ("VirtualSMC.kext",     "Contents/MacOS/VirtualSMC"),
    ("SMCProcessor.kext",   "Contents/MacOS/SMCProcessor"),
    ("SMCSuperIO.kext",     "Contents/MacOS/SMCSuperIO"),
    ("WhateverGreen.kext",  "Contents/MacOS/WhateverGreen"),
    ("AppleALC.kext",       "Contents/MacOS/AppleALC"),
    ("IntelMausi.kext",     "Contents/MacOS/IntelMausi"),
    ("NVMeFix.kext",        "Contents/MacOS/NVMeFix"),
    ("RestrictEvents.kext", "Contents/MacOS/RestrictEvents"),
    ("USBToolBox.kext",     "Contents/MacOS/USBToolBox"),
    ("UTBMap.kext",         ""),           # codeless map kext
]
d["Kernel"]["Add"] = [
    {"Arch": "x86_64", "BundlePath": b, "Comment": "", "Enabled": True,
     "ExecutablePath": e, "MaxKernel": "", "MinKernel": "",
     "PlistPath": "Contents/Info.plist"} for b, e in KEXTS
]
d["Kernel"]["Block"] = []
d["Kernel"]["Force"] = []
d["Kernel"]["Patch"] = []
kq = d["Kernel"]["Quirks"]
for k in kq:
    if isinstance(kq[k], bool):
        kq[k] = False
for k in ("AppleCpuPmCfgLock",        # HP BIOS has no CFG-Lock toggle
          "AppleXcpmCfgLock",         # ditto
          "DisableRtcChecksum",       # HP POSTs "system time is invalid" without this:
                                      # stops AppleRTC writing the CMOS primary
                                      # checksum at 0x58-0x59
          "DisableIoMapper",          # VT-d is off / not macOS friendly
          "DisableLinkeditJettison",  # Lilu, always on for 11+
          "LapicKernelPanic",         # HP firmware sends spurious LAPIC interrupts
          "PanicNoKextDump",
          "PowerTimeoutKernelPanic"):
    kq[k] = True
# XhciPortLimit deliberately FALSE: broken on 11.3+ (boot loops) and unnecessary
# because UTBMap.kext already maps this machine's ports.
kq["XhciPortLimit"] = False
kq["SetApfsTrimTimeout"] = -1
d["Kernel"]["Scheme"]["KernelArch"] = "x86_64"
d["Kernel"]["Emulate"] = {"Cpuid1Data": b"", "Cpuid1Mask": b"",
                          "DummyPowerManagement": False,
                          "MaxKernel": "", "MinKernel": ""}

# ---------------- Misc ----------------
boot = d["Misc"]["Boot"]
boot.update(HideAuxiliary=False, PickerAttributes=17, PickerMode="Builtin",
            PollAppleHotKeys=True, ShowPicker=True, Timeout=0,
            TakeoffDelay=0, LauncherOption="Disabled", LauncherPath="Default")
dbg = d["Misc"]["Debug"]
dbg.update(AppleDebug=True, ApplePanic=True, DisableWatchDog=True,
           DisplayDelay=0, DisplayLevel=0x80000042, LogModules="*",
           SysReport=False, Target=67)        # 67 = on-screen + log file on the USB
sec = d["Misc"]["Security"]
sec.update(AllowSetDefault=True, ApECID=0, AuthRestart=False,
           BlacklistAppleUpdate=True, DmgLoading="Signed", EnablePassword=False,
           ExposeSensitiveData=6, HaltLevel=0x80000000, ScanPolicy=0,
           SecureBootModel="Disabled", Vault="Optional")
d["Misc"]["Tools"] = [
    {"Arguments": "", "Auxiliary": True, "Comment": "UEFI shell",
     "Enabled": True, "Flavour": "Auto", "FullNvramAccess": False,
     "Name": "OpenShell", "Path": "OpenShell.efi",
     "RealPath": False, "TextMode": False}
]
d["Misc"]["Entries"] = []

# ---------------- NVRAM ----------------
BOOT_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
d["NVRAM"]["Add"] = {
    "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": {
        "DefaultBackgroundColor": h("00000000"),
    },
    "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102": {
        "rtc-blacklist": b"",
    },
    BOOT_GUID: {
        "ForceDisplayRotationInEFI": 0,
        "SystemAudioVolume": h("46"),
        "boot-args": BOOT_ARGS,
        "csr-active-config": h("00000000"),
        "prev-lang:kbd": b"en-US:0",
        "run-efi-updater": "No",
    },
}
d["NVRAM"]["Delete"] = {
    "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": ["DefaultBackgroundColor"],
    "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102": ["rtc-blacklist"],
    BOOT_GUID: ["ForceDisplayRotationInEFI", "boot-args", "csr-active-config",
                "prev-lang:kbd", "run-efi-updater"],
}
d["NVRAM"]["WriteFlash"] = True

# ---------------- PlatformInfo ----------------
pi = d["PlatformInfo"]
pi["Automatic"] = True
pi["CustomMemory"] = False
pi["UpdateDataHub"] = True
pi["UpdateNVRAM"] = True
pi["UpdateSMBIOS"] = True
pi["UpdateSMBIOSMode"] = "Create"
pi["UseRawUuidEncoding"] = False
g = pi["Generic"]
g.update(AdviseFeatures=False, MaxBIOSVersion=False, ProcessorType=0,
         SpoofVendor=True, SystemMemoryStatus="Auto", **SMBIOS)

# ---------------- UEFI ----------------
u = d["UEFI"]
u["ConnectDrivers"] = True
u["Drivers"] = [
    {"Arguments": "", "Comment": "HFS+ volumes (macOS installer/recovery)",
     "Enabled": True, "HideVerbose": False, "LoadEarly": False, "Path": "HfsPlus.efi"},
    {"Arguments": "", "Comment": "OpenCore runtime (required)",
     "Enabled": True, "HideVerbose": False, "LoadEarly": False, "Path": "OpenRuntime.efi"},
    {"Arguments": "--preserve-boot", "Comment": "Reset NVRAM boot entry",
     "Enabled": True, "HideVerbose": False, "LoadEarly": False, "Path": "ResetNvramEntry.efi"},
]
u["APFS"].update(EnableJumpstart=True, GlobalConnect=False, HideVerbose=True,
                 JumpstartHotPlug=False, MinDate=0, MinVersion=0)
uq = u["Quirks"]
for k in uq:
    if isinstance(uq[k], bool):
        uq[k] = False
uq["EnableVectorAcceleration"] = True
uq["RequestBootVarRouting"] = True
uq["ResizeGpuBars"] = -1
uq["TscSyncTimeout"] = 0
u["Output"]["ProvideConsoleGop"] = True
u["ReservedMemory"] = []

plistlib.dump(d, open(OUT, "wb"), sort_keys=True)
print("wrote", OUT)
