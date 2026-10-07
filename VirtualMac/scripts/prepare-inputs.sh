#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

: "${VZ_MACOS_IPSW:?set VZ_MACOS_IPSW to the 13.2.1 22D68 restore image URL}"
if vz_has_ipados_target 14; then
    : "${VZ_BIG_SUR_IPSW:?set VZ_BIG_SUR_IPSW to the 11.6 20G165 restore image URL}"
    : "${VZ_IPADOS14_IPSW:?set VZ_IPADOS14_IPSW to the 14.5 18E199 restore image URL}"
fi
INCLUDE_IPADOS_AUDIT="${VZ_INCLUDE_IPADOS_AUDIT:-0}"
if [[ -n "${VZ_IPADOS_IPSW:-}" ]]; then
    INCLUDE_IPADOS_AUDIT=1
fi
[[ "$INCLUDE_IPADOS_AUDIT" == 0 || "$INCLUDE_IPADOS_AUDIT" == 1 ]] ||
    die "VZ_INCLUDE_IPADOS_AUDIT must be 0 or 1"
if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
    : "${VZ_IPADOS_IPSW:?set VZ_IPADOS_IPSW for the full iPadOS audit}"
fi
IPSW="$VZ_BUILD_ROOT/toolchain/bin/ipsw-a2sb"
MAC_OUT="$VZ_BUILD_ROOT/inputs/macos"
IPAD_OUT="$VZ_BUILD_ROOT/inputs/ipados"
IPAD14_OUT="$VZ_BUILD_ROOT/inputs/ipados14"
MAC_ROOT="$MAC_OUT/22D68__MacOS"
BIG_SUR_ROOT="$VZ_BUILD_ROOT/inputs/macos11/20G165__MacOS"
DSC="$MAC_ROOT/dyld_shared_cache_arm64e"
BIG_SUR_DSC="$BIG_SUR_ROOT/dyld_shared_cache_arm64e"
BIG_SUR_INTERNET_SHARING="$BIG_SUR_ROOT/usr/libexec/InternetSharing"
BIG_SUR_RTADVD="$BIG_SUR_ROOT/usr/sbin/rtadvd"
BIG_SUR_NETWORK_SHARING_PLIST="$BIG_SUR_ROOT/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
BIG_SUR_BOOTPD_PLIST="$BIG_SUR_ROOT/System/Library/LaunchDaemons/bootps.plist"
IPAD14_ROOT=""
IPAD14_BOOTPD=""
IPAD_DSC="$IPAD_OUT/20D67__iPad14,3_4_5_6/dyld_shared_cache_arm64e"
VZ_ROOT="$MAC_ROOT/System/Library/Frameworks/Virtualization.framework/Versions/A"
VMM="$VZ_ROOT/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
EVENT_TAP="$VZ_ROOT/XPCServices/com.apple.Virtualization.EventTap.xpc/Contents/MacOS/com.apple.Virtualization.EventTap"
RES="$VZ_ROOT/Resources"
HV_INFO="$MAC_ROOT/System/Library/Frameworks/Hypervisor.framework/Versions/A/Resources/Info.plist"
PVG_INFO="$MAC_ROOT/System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/Info.plist"
METAL_SERIALIZER_INFO="$MAC_ROOT/System/Library/PrivateFrameworks/MetalSerializer.framework/Versions/A/Resources/Info.plist"
DISKIMAGES2_INFO="$MAC_ROOT/System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/Resources/Info.plist"
VZ_LOCALIZABLE="$RES/Localizable.loctable"
THIN="$MAC_OUT/VirtualMachine.arm64e"
MANIFEST="$VZ_BUILD_ROOT/inputs/manifest.txt"
INTERNET_SHARING="$MAC_ROOT/usr/libexec/InternetSharing"
BOOTPD="$MAC_ROOT/usr/libexec/bootpd"
RTADVD="$MAC_ROOT/usr/sbin/rtadvd"
NETWORK_SHARING_PLIST="$MAC_ROOT/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
BOOTPD_PLIST="$MAC_ROOT/System/Library/LaunchDaemons/bootps.plist"

if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
    [[ -n "$VZ_IPADOS_IPSW" ]] || die "VZ_IPADOS_IPSW must be set for the full iPadOS audit"
fi
need_file "$IPSW"
need_command aria2c
need_command codesign
need_command lipo
need_command shasum

mkdir -p "$MAC_OUT" "$IPAD_OUT"
mkdir -p "$IPAD14_OUT"

if [[ ! -f "$DSC" || ! -f "$DSC.01" ]]; then
    "$IPSW" extract --remote --dyld --dyld-arch arm64e         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

download_local() {
    local url="$1"
    local expected="$2"
    local name="$(basename "$url")"
    local out="$VZ_BUILD_ROOT/inputs/.downloads/$name"
    mkdir -p "$(dirname "$out")"

    if [[ ! -f "$out" ]]; then
        echo "Downloading local-extract input: $name" >&2
        aria2c --continue=true --allow-overwrite=false --auto-file-renaming=false             --max-connection-per-server=8 --split=8 --min-split-size=10M             --summary-interval=15 --console-log-level=notice             --dir="$(dirname "$out")" --out="$name" "$url" >&2
    fi

    local actual
    actual="$(shasum -a 256 "$out" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        rm -f "$out"
        die "SHA-256 mismatch for $name: expected $expected, got $actual"
    }
    printf '%s\n' "$out"
}

if [[ ! -f "$BIG_SUR_DSC" || ! -f "$BIG_SUR_INTERNET_SHARING" ||
      ! -f "$BIG_SUR_RTADVD" || ! -f "$BIG_SUR_NETWORK_SHARING_PLIST" ||
      ! -f "$BIG_SUR_BOOTPD_PLIST" ]]; then
    BIG_SUR_LOCAL="$(download_local         "$VZ_BIG_SUR_IPSW"         "9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6")"

    if [[ ! -f "$BIG_SUR_DSC" ]]; then
        "$IPSW" extract --dyld --dyld-arch arm64e             --output "$VZ_BUILD_ROOT/inputs/macos11" "$BIG_SUR_LOCAL"
    fi

    if [[ ! -f "$BIG_SUR_INTERNET_SHARING" || ! -f "$BIG_SUR_RTADVD" ||
          ! -f "$BIG_SUR_NETWORK_SHARING_PLIST" ||
          ! -f "$BIG_SUR_BOOTPD_PLIST" ]]; then
        "$IPSW" extract --files             --pattern '^(usr/libexec/InternetSharing|usr/sbin/rtadvd|System/Library/LaunchDaemons/(com\.apple\.NetworkSharing\.plist|bootps\.plist))$'             --output "$VZ_BUILD_ROOT/inputs/macos11" "$BIG_SUR_LOCAL"
    fi

    rm -f "$BIG_SUR_LOCAL"
    rmdir "$VZ_BUILD_ROOT/inputs/.downloads" 2>/dev/null || true
fi

if vz_has_ipados_target 14; then
if [[ -z "$IPAD14_BOOTPD" ]]; then
    IPAD14_LOCAL="$(download_local         "$VZ_IPADOS14_IPSW"         "e6ac263ae3124aa4ca1424ec9d395b0d798c349e9c31f9964783e1ddf58b1446")"
    "$IPSW" extract --files         --pattern '^usr/libexec/bootpd
    rmdir "$VZ_BUILD_ROOT/inputs/.downloads" 2>/dev/null || true
fi

fi
if [[ ! -f "$VMM" || ! -f "$EVENT_TAP" || ! -f "$VZ_LOCALIZABLE" ||
      ! -f "$HV_INFO" || ! -f "$PVG_INFO" ||
      ! -f "$METAL_SERIALIZER_INFO" || ! -f "$DISKIMAGES2_INFO" ]]; then
    "$IPSW" extract --remote --files         --pattern '^(System/Library/Frameworks/(Hypervisor|ParavirtualizedGraphics|Virtualization)\.framework/Versions/A/(Resources/.*|XPCServices/.*)|System/Library/PrivateFrameworks/(MetalSerializer|DiskImages2)\.framework/Versions/A/Resources/.*)$'         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

if [[ ! -f "$INTERNET_SHARING" || ! -f "$BOOTPD" ||
      ! -f "$RTADVD" || ! -f "$NETWORK_SHARING_PLIST" ||
      ! -f "$BOOTPD_PLIST" ]]; then
    "$IPSW" extract --remote --files         --pattern '^(usr/libexec/(InternetSharing|bootpd)|usr/sbin/rtadvd|System/Library/LaunchDaemons/(com\.apple\.NetworkSharing\.plist|bootps\.plist))$'         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

MAC_KERNEL="$MAC_OUT/22D68__MacBookAir10,1/kernelcache.release.MacBookAir10,1_MacBookPro17,1_Macmini9,1_iMac21,1_2"
if [[ ! -f "$MAC_KERNEL" ]]; then
    "$IPSW" extract --remote --kernel --device MacBookAir10,1         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

IPAD_KERNEL="$IPAD_OUT/20D67__iPad14,6/kernelcache.release.iPad14,3_4_5_6"
if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
    if [[ ! -f "$IPAD_KERNEL" ]]; then
        "$IPSW" extract --remote --kernel --device iPad14,6             --output "$IPAD_OUT" "$VZ_IPADOS_IPSW"
    fi

    if [[ ! -f "$IPAD_DSC" || ! -f "$IPAD_DSC.01" ]]; then
        "$IPSW" extract --remote --dyld --dyld-arch arm64e             --output "$IPAD_OUT" "$VZ_IPADOS_IPSW"
    fi
fi

lipo "$VMM" -thin arm64e -output "$THIN"

assert_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "hash mismatch for $file: expected $expected, got $actual"
}

assert_sha256 "$THIN"     e96f04f6daf44ecb5199e7c67c458e58a6276606c64e42cf354b9fe4feb188aa
assert_sha256 "$RES/AVPBooter.vmapple2.bin"     758e18c43a049448dd8fd1100968503bc13ced11b1619aa40a72377b7fddac24
assert_sha256 "$RES/VZG11.fd"     106605b56eb9927a4d1d9eed038f90fed5a5aa95f1ad588a020cea50e1932a88
assert_sha256 "$RES/VZG21.fd"     51ffd0f3adc9ae7c7ed59f829405aa2dfed584f8208de4bceed067a749312cb3
assert_sha256 "$INTERNET_SHARING"     2df10d5444f99b68226234e67ffc1ee463b0ccb87bb10538ccc4fbcc277d7541
assert_sha256 "$BOOTPD"     3cb7b984f544b4bbd151cca952d7f3fbe208f7e3f1e06715446cabadcaf4d0b7
assert_sha256 "$RTADVD"     9eab82037da516d8ac92fd90b01a2ef6f871e5ab70c3f5d1c67566affd26fdf3
assert_sha256 "$NETWORK_SHARING_PLIST"     4b7538f63d2abc33fe05ac82ed9b441012e12b2116af4b2e34113abfa828d591
assert_sha256 "$BOOTPD_PLIST"     04cb8e8e584d8a4e1595dd78ea71b56592c8bbe9ab56371c9e19eeb51ae504b0
assert_sha256 "$METAL_SERIALIZER_INFO"     a0fdc113e5aeecc56fff3023cb48880b627e4ae1056c7bc5a9ac8324d3b13345

hash_line() {
    local label="$1"
    local file="$2"
    printf '%s\t%s\t%s\t%s\n'         "$label"         "$(stat -f %z "$file")"         "$(shasum -a 256 "$file" | awk '{print $1}')"         "$file"
}

{
    printf 'INPUT_MANIFEST\t1\n'
    printf 'generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repository_commit\t%s\n' "$(git -C "$VZ_REPO_ROOT" rev-parse HEAD)"
    printf 'ipsw_tool_commit\t%s\n'         "$(git -C "$VZ_BUILD_ROOT/toolchain/ipsw-src" rev-parse HEAD)"
    printf 'python\t%s\n' "$("$VZ_BUILD_ROOT/toolchain/venv/bin/python3" --version 2>&1)"
    printf 'dyldextractor\t2.2.2+VirtualMac-arm64e\n'
    printf 'macos_ipsw_sha256\t%s\n' '0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04'
    printf 'big_sur_ipsw_sha256\t%s\n' '9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6'
    if vz_has_ipados_target 14; then
        printf 'ipados14_ipsw_sha256\t%s\n' 'e6ac263ae3124aa4ca1424ec9d395b0d798c349e9c31f9964783e1ddf58b1446'
    else
        printf 'ipados14_ipsw_sha256\tskipped\n'
    fi
    hash_line big_sur_dsc "$BIG_SUR_DSC"
    hash_line macos_dsc "$DSC"
    hash_line macos_dsc_01 "$DSC.01"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        printf 'ipados_ipsw_url\t%s\n' "$VZ_IPADOS_IPSW"
        hash_line ipados_dsc "$IPAD_DSC"
    else
        printf 'ipados_audit\tskipped\n'
    fi
    hash_line vmm_fat "$VMM"
    hash_line vmm_arm64e "$THIN"
    hash_line avpbooter "$RES/AVPBooter.vmapple2.bin"
    hash_line vzg11 "$RES/VZG11.fd"
    hash_line vzg21 "$RES/VZG21.fd"
    hash_line macos_kernel "$MAC_KERNEL"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        hash_line ipados_kernel "$IPAD_KERNEL"
    fi
    hash_line internet_sharing "$INTERNET_SHARING"
    hash_line bootpd "$BOOTPD"
    if vz_has_ipados_target 14; then
        hash_line ipados14_bootpd "$IPAD14_BOOTPD"
    fi
    hash_line rtadvd "$RTADVD"
    hash_line metal_serializer_info "$METAL_SERIALIZER_INFO"
    printf 'macos_kernel_version\t%s\n'         "$( "$IPSW" kernel version "$MAC_KERNEL")"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        printf 'ipados_kernel_version\t%s\n'             "$( "$IPSW" kernel version "$IPAD_KERNEL")"
    fi
    printf 'vmm_uuid\t%s\n'         "$(dwarfdump --uuid "$THIN" | awk '{print $2}')"
    printf 'vmm_entitlements_begin\n'
    codesign -d --entitlements :- "$VMM" 2>&1
    printf 'vmm_entitlements_end\n'
} > "$MANIFEST"

cat <<EOF
inputs ready and verified:
  DSC: $DSC
  VMM: $THIN
  resources: $RES
  manifest: $MANIFEST
EOF
         --output "$IPAD14_OUT" "$IPAD14_LOCAL"
    rm -f "$IPAD14_LOCAL"
    # IPSW identities may name this restore image with a different board list
    # than the historical 13,4_5_6_7 directory. Resolve the extracted file
    # by content path instead of hard-coding the identity directory.
    IPAD14_BOOTPD="$(find "$IPAD14_OUT" -type f -path '*/usr/libexec/bootpd' -print -quit)"
    [[ -n "$IPAD14_BOOTPD" ]] || die "iPadOS 14 bootpd extraction produced no usr/libexec/bootpd"
    IPAD14_ROOT="${IPAD14_BOOTPD%/usr/libexec/bootpd}"
    rmdir "$VZ_BUILD_ROOT/inputs/.downloads" 2>/dev/null || true
fi

if [[ ! -f "$VMM" || ! -f "$EVENT_TAP" || ! -f "$VZ_LOCALIZABLE" ||
      ! -f "$HV_INFO" || ! -f "$PVG_INFO" ||
      ! -f "$METAL_SERIALIZER_INFO" || ! -f "$DISKIMAGES2_INFO" ]]; then
    "$IPSW" extract --remote --files         --pattern '^(System/Library/Frameworks/(Hypervisor|ParavirtualizedGraphics|Virtualization)\.framework/Versions/A/(Resources/.*|XPCServices/.*)|System/Library/PrivateFrameworks/(MetalSerializer|DiskImages2)\.framework/Versions/A/Resources/.*)$'         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

if [[ ! -f "$INTERNET_SHARING" || ! -f "$BOOTPD" ||
      ! -f "$RTADVD" || ! -f "$NETWORK_SHARING_PLIST" ||
      ! -f "$BOOTPD_PLIST" ]]; then
    "$IPSW" extract --remote --files         --pattern '^(usr/libexec/(InternetSharing|bootpd)|usr/sbin/rtadvd|System/Library/LaunchDaemons/(com\.apple\.NetworkSharing\.plist|bootps\.plist))$'         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

MAC_KERNEL="$MAC_OUT/22D68__MacBookAir10,1/kernelcache.release.MacBookAir10,1_MacBookPro17,1_Macmini9,1_iMac21,1_2"
if [[ ! -f "$MAC_KERNEL" ]]; then
    "$IPSW" extract --remote --kernel --device MacBookAir10,1         --output "$MAC_OUT" "$VZ_MACOS_IPSW"
fi

IPAD_KERNEL="$IPAD_OUT/20D67__iPad14,6/kernelcache.release.iPad14,3_4_5_6"
if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
    if [[ ! -f "$IPAD_KERNEL" ]]; then
        "$IPSW" extract --remote --kernel --device iPad14,6             --output "$IPAD_OUT" "$VZ_IPADOS_IPSW"
    fi

    if [[ ! -f "$IPAD_DSC" || ! -f "$IPAD_DSC.01" ]]; then
        "$IPSW" extract --remote --dyld --dyld-arch arm64e             --output "$IPAD_OUT" "$VZ_IPADOS_IPSW"
    fi
fi

lipo "$VMM" -thin arm64e -output "$THIN"

assert_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "hash mismatch for $file: expected $expected, got $actual"
}

assert_sha256 "$THIN"     e96f04f6daf44ecb5199e7c67c458e58a6276606c64e42cf354b9fe4feb188aa
assert_sha256 "$RES/AVPBooter.vmapple2.bin"     758e18c43a049448dd8fd1100968503bc13ced11b1619aa40a72377b7fddac24
assert_sha256 "$RES/VZG11.fd"     106605b56eb9927a4d1d9eed038f90fed5a5aa95f1ad588a020cea50e1932a88
assert_sha256 "$RES/VZG21.fd"     51ffd0f3adc9ae7c7ed59f829405aa2dfed584f8208de4bceed067a749312cb3
assert_sha256 "$INTERNET_SHARING"     2df10d5444f99b68226234e67ffc1ee463b0ccb87bb10538ccc4fbcc277d7541
assert_sha256 "$BOOTPD"     3cb7b984f544b4bbd151cca952d7f3fbe208f7e3f1e06715446cabadcaf4d0b7
assert_sha256 "$RTADVD"     9eab82037da516d8ac92fd90b01a2ef6f871e5ab70c3f5d1c67566affd26fdf3
assert_sha256 "$NETWORK_SHARING_PLIST"     4b7538f63d2abc33fe05ac82ed9b441012e12b2116af4b2e34113abfa828d591
assert_sha256 "$BOOTPD_PLIST"     04cb8e8e584d8a4e1595dd78ea71b56592c8bbe9ab56371c9e19eeb51ae504b0
assert_sha256 "$METAL_SERIALIZER_INFO"     a0fdc113e5aeecc56fff3023cb48880b627e4ae1056c7bc5a9ac8324d3b13345

hash_line() {
    local label="$1"
    local file="$2"
    printf '%s\t%s\t%s\t%s\n'         "$label"         "$(stat -f %z "$file")"         "$(shasum -a 256 "$file" | awk '{print $1}')"         "$file"
}

{
    printf 'INPUT_MANIFEST\t1\n'
    printf 'generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repository_commit\t%s\n' "$(git -C "$VZ_REPO_ROOT" rev-parse HEAD)"
    printf 'ipsw_tool_commit\t%s\n'         "$(git -C "$VZ_BUILD_ROOT/toolchain/ipsw-src" rev-parse HEAD)"
    printf 'python\t%s\n' "$("$VZ_BUILD_ROOT/toolchain/venv/bin/python3" --version 2>&1)"
    printf 'dyldextractor\t2.2.2+VirtualMac-arm64e\n'
    printf 'macos_ipsw_sha256\t%s\n' '0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04'
    printf 'big_sur_ipsw_sha256\t%s\n' '9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6'
    printf 'ipados14_ipsw_sha256\t%s\n' 'e6ac263ae3124aa4ca1424ec9d395b0d798c349e9c31f9964783e1ddf58b1446'
    hash_line big_sur_dsc "$BIG_SUR_DSC"
    hash_line macos_dsc "$DSC"
    hash_line macos_dsc_01 "$DSC.01"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        printf 'ipados_ipsw_url\t%s\n' "$VZ_IPADOS_IPSW"
        hash_line ipados_dsc "$IPAD_DSC"
    else
        printf 'ipados_audit\tskipped\n'
    fi
    hash_line vmm_fat "$VMM"
    hash_line vmm_arm64e "$THIN"
    hash_line avpbooter "$RES/AVPBooter.vmapple2.bin"
    hash_line vzg11 "$RES/VZG11.fd"
    hash_line vzg21 "$RES/VZG21.fd"
    hash_line macos_kernel "$MAC_KERNEL"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        hash_line ipados_kernel "$IPAD_KERNEL"
    fi
    hash_line internet_sharing "$INTERNET_SHARING"
    hash_line bootpd "$BOOTPD"
    hash_line ipados14_bootpd "$IPAD14_BOOTPD"
    hash_line rtadvd "$RTADVD"
    hash_line metal_serializer_info "$METAL_SERIALIZER_INFO"
    printf 'macos_kernel_version\t%s\n'         "$( "$IPSW" kernel version "$MAC_KERNEL")"
    if [[ "$INCLUDE_IPADOS_AUDIT" == 1 ]]; then
        printf 'ipados_kernel_version\t%s\n'             "$( "$IPSW" kernel version "$IPAD_KERNEL")"
    fi
    printf 'vmm_uuid\t%s\n'         "$(dwarfdump --uuid "$THIN" | awk '{print $2}')"
    printf 'vmm_entitlements_begin\n'
    codesign -d --entitlements :- "$VMM" 2>&1
    printf 'vmm_entitlements_end\n'
} > "$MANIFEST"

cat <<EOF
inputs ready and verified:
  DSC: $DSC
  VMM: $THIN
  resources: $RES
  manifest: $MANIFEST
EOF
