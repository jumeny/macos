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

# Binary payloads may legitimately contain RootHide APIs and the
# runtime's /.jbroot- detection marker. Audit path-bearing package metadata
# instead of treating arbitrary binary strings as path leaks.
for item in stage.rglob("*"):
    if not item.is_file() or item.is_symlink():
        continue
    if "DEBIAN" not in item.parts and item.suffix != ".plist":
        continue
    try:
        data = item.read_text(errors="ignore")
    except OSError:
        continue
    for forbidden in ("/var/jb/", "/var/root/VirtualMac"):
        if forbidden in data:
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
