#!/usr/bin/env python3
import pathlib
import plistlib
import subprocess
import sys

stage = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
if stage is None or not stage.is_dir():
    raise SystemExit("usage: audit-roothide-package-stage.py STAGE")

control = (stage / "DEBIAN/control").read_text()
required = [
    "Package: com.mac.virtual",
    "Version: 0.0.1b+rh",
    "Architecture: iphoneos-arm64e",
    "Depends: firmware (>= 16.0), firmware (<< 16.4), roothide",
]
for line in required:
    if line not in control:
        raise SystemExit(f"missing control field: {line}")

for forbidden in ("/var/jb/", "/var/root/VirtualMac", ".jbroot-"):
    for item in stage.rglob("*"):
        if item.is_file() and not item.is_symlink():
            try:
                data = item.read_bytes()
            except OSError:
                continue
            if forbidden.encode() in data:
                raise SystemExit(f"forbidden absolute RootHide path leaked into {item}: {forbidden}")

runtime = stage / "User/Library/VirtualMac"
app = stage / "Applications/VirtualMac.app"
for item in (
    runtime / "payload/Frameworks/Virtualization.framework/Virtualization",
    runtime / "payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
    runtime / "payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation",
    runtime / "install/install-launcher",
    runtime / "install/install-macos",
    app / "VirtualMac",
    stage / "usr/lib/VirtualMacPaths.dylib",
):
    if not item.is_file():
        raise SystemExit(f"missing RootHide payload file: {item}")

vmm = runtime / "payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
installer = runtime / "payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
for item in (vmm, installer):
    subprocess.run(["otool", "-L", str(item)], check=True, stdout=subprocess.DEVNULL)

plists = list((stage / "Library/LaunchDaemons").glob("*.plist"))
for plist in plists:
    value = plistlib.loads(plist.read_bytes())
    for key in ("Program", "ProgramArguments"):
        raw = value.get(key)
        values = raw if isinstance(raw, list) else [raw] if raw else []
        for path in values:
            if isinstance(path, str) and ("/var/jb/" in path or "/var/root/VirtualMac" in path):
                raise SystemExit(f"hard-coded jailbreak path in {plist}: {path}")

print("RootHide package audit passed")
