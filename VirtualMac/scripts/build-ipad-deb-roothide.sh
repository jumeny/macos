#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command dpkg-deb
need_command ditto
need_command find
need_command ldid
need_command otool
need_command plutil
need_command python3
need_command rsync
need_command shasum
need_command xcrun

BASE_DEB="${VZ_BASE_DEB:-$VZ_BUILD_ROOT/downloads/VirtualMac_1.2.3.deb}"
BASE_SHA256=435ce1dc76b9e18b1547c77b84e2cf33ffe40a16be63e366f181d14709a41aa0
need_file "$BASE_DEB"
actual="$(shasum -a 256 "$BASE_DEB" | awk '{print $1}')"
if [[ "$actual" != "$BASE_SHA256" ]]; then
    if [[ "${VZ_ALLOW_UNVERIFIED_BASE:-0}" != "1" ]]; then
        die "base Virtual Mac 1.2.3 checksum mismatch: $actual"
    fi
    echo "WARNING: accepting unverified base package checksum $actual" >&2
fi

export VZ_ROOTHIDE=1
export VZ_IPADOS_MIN_VERSION="${VZ_IPADOS_MIN_VERSION:-16.0}"
ROOTHIDE_SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
if [[ ! -f "$ROOTHIDE_SDK/roothide.h" ]]; then
    "$SCRIPT_DIR/development/prepare-roothide-sdk.sh"
fi
need_file "$ROOTHIDE_SDK/roothide.h"
need_file "$ROOTHIDE_SDK/roothide/libroothide.tbd"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/release-roothide"
STAGE="$OUT/stage"
SOURCE="$OUT/base-$BASE_SHA256"
RUNTIME="$STAGE/User/Library/VirtualMac"
APP="$STAGE/Applications/VirtualMac.app"
PAYLOAD="$RUNTIME/payload"
INSTALL="$RUNTIME/install"

rm -rf "$OUT"
mkdir -p "$STAGE/DEBIAN" "$STAGE/Applications" "$STAGE/User/Library"
dpkg-deb -x "$BASE_DEB" "$SOURCE"
mkdir -p "$RUNTIME"
rsync -a "$SOURCE/var/root/VirtualMac/payload/" "$PAYLOAD/"
rsync -a "$SOURCE/var/root/VirtualMac/install/" "$INSTALL/"
rsync -a "$SOURCE/var/root/VirtualMac/bootstrap-common/" "$RUNTIME/bootstrap-common/"
rsync -a "$SOURCE/var/root/VirtualMac/rootful/" "$RUNTIME/rootful/"
rsync -a "$SOURCE/var/root/VirtualMac/bootstrap-rootful/" "$RUNTIME/bootstrap-rootful/"
rsync -a "$SOURCE/var/jb/Applications/VirtualMac.app/" "$APP/"
mkdir -p "$STAGE/usr/lib" "$STAGE/usr/libexec" "$STAGE/usr/sbin" "$STAGE/usr/bin" "$STAGE/Library/LaunchDaemons"
rsync -a "$SOURCE/var/jb/usr/lib/" "$STAGE/usr/lib/"
rsync -a "$SOURCE/var/jb/usr/libexec/" "$STAGE/usr/libexec/"
rsync -a "$SOURCE/var/jb/usr/sbin/" "$STAGE/usr/sbin/"
rsync -a "$SOURCE/var/jb/usr/bin/" "$STAGE/usr/bin/" 2>/dev/null || true
rsync -a "$SOURCE/var/jb/Library/LaunchDaemons/" "$STAGE/Library/LaunchDaemons/" 2>/dev/null || true

# Rebuild the RootHide-aware app and VMM hook, but do not extract any IPSW.
VZ_ROOTHIDE_SDK="$ROOTHIDE_SDK" "$SCRIPT_DIR/build-ipad-app.sh"
VZ_ROOTHIDE_SDK="$ROOTHIDE_SDK" VZ_VMM_COMPAT_OUTPUT="$PAYLOAD/Frameworks/LaunchServicesCompat.dylib"     "$SCRIPT_DIR/build-vmm-compat.sh"

ditto "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app" "$APP"
mkdir -p "$RUNTIME/install"
cp "$VZ_BUILD_ROOT/ipad-app/virtualmac-diagnostics" "$STAGE/usr/bin/virtualmac-diagnostics"
cp "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app/VZHostCompat.dylib" "$INSTALL/VZHostCompat.dylib"
chmod 755 "$STAGE/usr/bin/virtualmac-diagnostics" "$INSTALL/VZHostCompat.dylib"
rm -f "$APP/_CodeSignature/CodeResources"

# Select the already-built iPadOS 16 runtime images from the base package.
VMM="$PAYLOAD/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
INSTALLER="$PAYLOAD/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
cp "$VMM.ipados16" "$VMM"
cp "$INSTALLER.ipados16" "$INSTALLER"
cp "$STAGE/usr/libexec/InternetSharing.ipados16" "$STAGE/usr/libexec/InternetSharing"
cp "$PAYLOAD/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados16"    "$PAYLOAD/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib"

# Rebuild only the lightweight installation shim and RootHide-aware installer
# helpers. The heavy MobileDevice/VMM binaries come from the verified base.
INSTALL_COMPAT="$PAYLOAD/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION"     -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK"     -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup     -framework CoreFoundation -framework IOKit     -Wl,-reexport_library,"$ROOT/VirtualMac/vz/host/DiskArbitration-iOS.tbd"     -install_name "@rpath/InstallationCompat.dylib"     "$ROOT/VirtualMac/vz/host/installationhook.m"     "$ROOT/VirtualMac/vz/host/installation_usb_shim.m"     -L"$ROOTHIDE_SDK/roothide" -lroothide -o "$INSTALL_COMPAT"

xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION"     -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK"     "$ROOT/VirtualMac/vz/install/install_launcher.c"     -L"$ROOTHIDE_SDK/roothide" -lroothide -o "$INSTALL/install-launcher"

xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION"     -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK" -fblocks     -framework Foundation -framework Metal -framework UIKit     -Wl,-export_dynamic "$ROOT/VirtualMac/vz/host/NSViewShim.m"     "$ROOT/VirtualMac/vz/install/install_macos.m"     -L"$ROOTHIDE_SDK/roothide" -lroothide -o "$INSTALL/install-macos"

cp "$ROOT/VirtualMac/vz/install/start-install.sh" "$INSTALL/start-install.sh"
chmod 755 "$INSTALL/start-install.sh" "$INSTALL/install-launcher" "$INSTALL/install-macos"

# RootHide path interposition is kept beside each helper so no randomized
# jbroot is encoded in any Mach-O load command.
PATH_LIB="$STAGE/usr/lib/VirtualMacPaths.dylib"
mkdir -p "$(dirname "$PATH_LIB")"
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION"     -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK" -dynamiclib -Wall -Wextra -Werror     -lutil "$ROOT/VirtualMac/vz/host/roothide_paths.c"     -L"$ROOTHIDE_SDK/roothide" -lroothide -o "$PATH_LIB"

copy_path_lib() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    cp "$PATH_LIB" "$dir/VirtualMacPaths.dylib"
    python3 "$ROOT/VirtualMac/vz/patches/add_macho_dylib.py" "$target"         "@loader_path/VirtualMacPaths.dylib"
}

for helper in     "$VMM"     "$INSTALLER"     "$PAYLOAD/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados16"     "$PAYLOAD/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd"     "$PAYLOAD/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice"     "$STAGE/usr/libexec/InternetSharing"     "$STAGE/usr/libexec/bootpd"     "$STAGE/usr/sbin/rtadvd"; do
    [[ -f "$helper" ]] && copy_path_lib "$helper"
done

# Keep the iPadOS 16 host choice explicit in the package metadata and control
# paths; older host variants remain in the base runtime but are not selectable.
cat > "$STAGE/DEBIAN/control" <<'CONTROL'
Package: com.mac.virtual
Name: Virtual Mac RootHide
Version: 0.0.1b+rh
Architecture: iphoneos-arm64e
Description: Virtual Mac for RootHide on iPadOS 16.
Maintainer: Virtual Mac
Author: Virtual Mac
Section: Utilities
Priority: optional
Depends: firmware (>= 16.0), firmware (<< 16.4), roothide, dopamine-basebin-link, ellekit
Tag: role::enduser
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -eu
JBROOT="$(jbroot /)"
export JBROOT
RUNTIME="$JBROOT/User/Library/VirtualMac"
mkdir -p "$RUNTIME" /var/mobile/Media/VirtualMac
chmod 755 "$RUNTIME" "$RUNTIME/install" "$RUNTIME/payload" 2>/dev/null || true

host_version="$(sw_vers -productVersion)"
case "$host_version" in
    16.*) ;;
    *) echo "Virtual Mac RootHide: iPadOS 16.x is required" >&2; exit 1 ;;
esac

VMM="$RUNTIME/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
INSTALLER="$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
test -f "$VMM.ipados16"
test -f "$INSTALLER.ipados16"
test -f "$VMM"
test -f "$INSTALLER"

for plist in "$JBROOT/Library/LaunchDaemons/"*.plist; do
    test -f "$plist" || continue
    sed -i '' "s#/var/jb#$JBROOT#g; s#/var/root/VirtualMac#$RUNTIME#g" "$plist" 2>/dev/null || true
done

if command -v launchctl >/dev/null 2>&1; then
    for plist in "$JBROOT/Library/LaunchDaemons/com.apple.NetworkSharing.plist"                  "$JBROOT/Library/LaunchDaemons/com.apple.bootpd.plist"; do
        test -f "$plist" || continue
        label="$(sed -n '/<key>Label</{
            n
            s/.*<string>\([^<]*\)<\/string>.*/\1/p
            q
        }' "$plist" 2>/dev/null || true)"
        test -n "$label" && {
            launchctl bootstrap user/501 "$plist" 2>/dev/null ||
                launchctl bootstrap system "$plist" 2>/dev/null || true
        }
    done
fi
if command -v uicache >/dev/null 2>&1; then
    uicache -p "$JBROOT/Applications/VirtualMac.app" >/dev/null 2>&1 || true
fi
exit 0
POSTINST

cat > "$STAGE/DEBIAN/preinst" <<'PREINST'
#!/bin/sh
set -eu
JBROOT="$(jbroot /)"
export JBROOT
exit 0
PREINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -eu
JBROOT="$(jbroot /)"
export JBROOT
if command -v launchctl >/dev/null 2>&1; then
    for plist in "$JBROOT/Library/LaunchDaemons/com.apple.NetworkSharing.plist"                  "$JBROOT/Library/LaunchDaemons/com.apple.bootpd.plist"; do
        test -f "$plist" || continue
        label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || true)"
        test -n "$label" && launchctl bootout system "$label" 2>/dev/null || true
    done
fi
exit 0
PRERM

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -eu
if command -v uicache >/dev/null 2>&1; then
    JBROOT="$(jbroot /)"
    uicache -u "$JBROOT/Applications/VirtualMac.app" >/dev/null 2>&1 || true
fi
exit 0
POSTRM

# Copy the project's RootHide-specific source localization resources over the
# base app without touching guest/runtime payloads.
if [[ -d "$ROOT/VirtualMac/resources/Localizations" ]]; then
    for locale in "$ROOT/VirtualMac/resources/Localizations/"*.lproj; do
        name="$(basename "$locale")"
        mkdir -p "$APP/$name"
        [[ -f "$locale/Localizable.strings" ]] && cp "$locale/Localizable.strings" "$APP/$name/"
        [[ -f "$locale/InfoPlist.strings" ]] && cp "$locale/InfoPlist.strings" "$APP/$name/"
    done
fi

# Add RootHide storage entitlements while preserving the base executable's
# existing entitlement set.
python3 - "$STAGE" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

stage = pathlib.Path(sys.argv[1])
required = (
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.security.storage.AppDataContainers",
)
for file in stage.rglob("*"):
    if not file.is_file() or file.is_symlink():
        continue
    try:
        header = file.read_bytes()[:32]
    except OSError:
        continue
    if header[:4] not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        continue
    try:
        raw = subprocess.check_output(["ldid", "-e", str(file)], stderr=subprocess.DEVNULL)
        ent = plistlib.loads(raw) if raw.strip() else {}
    except Exception:
        continue
    changed = False
    for key in required:
        if ent.get(key) is not True:
            ent[key] = True
            changed = True
    if changed:
        ef = stage / ".roothide-entitlements.plist"
        ef.write_bytes(plistlib.dumps(ent))
        subprocess.run(["ldid", "-S" + str(ef), str(file)], check=True)
stage_ef = stage / ".roothide-entitlements.plist"
stage_ef.unlink(missing_ok=True)
PY

chmod 755 "$STAGE/DEBIAN/"*
python3 "$SCRIPT_DIR/audit-roothide-package-stage.py" "$STAGE"
rm -f "$OUT"/*.deb
mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/VirtualMac-RootHide-0.0.1b+rh.deb"
echo "RootHide package built: $OUT/VirtualMac-RootHide-0.0.1b+rh.deb"
