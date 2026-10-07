#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUTPUT="${VZ_VMM_COMPAT_OUTPUT:-$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/LaunchServicesCompat.dylib}"

RH_CFLAGS=()
RH_LDFLAGS=()
if [[ "${VZ_ROOTHIDE:-0}" == "1" ]]; then
    ROOTHIDE_SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
    need_file "$ROOTHIDE_SDK/roothide.h"
    need_file "$ROOTHIDE_SDK/roothide/libroothide.tbd"
    RH_CFLAGS=(-DVZ_ROOTHIDE -I"$ROOTHIDE_SDK")
    RH_LDFLAGS=(-L"$ROOTHIDE_SDK/roothide" -lroothide)
fi
ENTITLEMENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"

need_command ldid
need_command xcrun
need_file "$ENTITLEMENTS"
need_file "$VZ_REPO_ROOT/vz/host/lsshim.m"
need_file "$VZ_REPO_ROOT/vz/host/vmmhook.m"
need_file "$VZ_REPO_ROOT/vz/host/pvg_trace.m"

mkdir -p "$(dirname "$OUTPUT")"
xcrun --sdk iphoneos clang \
    "${RH_CFLAGS[@]}" \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    "${RH_LDFLAGS[@]}" \
    -o "$OUTPUT"
ldid -S"$ENTITLEMENTS" "$OUTPUT"

echo "VMM compatibility library built: $OUTPUT"
echo "CDHash: $(ldid -h "$OUTPUT" | sed -n 's/^CDHash=//p')"
