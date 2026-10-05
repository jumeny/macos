#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_DIR="$ROOT/build/downloads"
mkdir -p "$INPUT_DIR"

download() {
    local name="$1"
    local url="$2"
    local expected="$3"
    local out="$INPUT_DIR/$name"

    if [[ -f "$out" ]]; then
        echo "Checking cached $name"
    else
        echo "Downloading $name"
        aria2c --continue=true --allow-overwrite=false --auto-file-renaming=false \
            --max-connection-per-server=8 --split=8 --min-split-size=10M \
            --summary-interval=15 --console-log-level=notice \
            --dir="$INPUT_DIR" --out="$name" "$url"
    fi

    local actual
    actual="$(shasum -a 256 "$out" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: SHA-256 mismatch for $name" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        rm -f "$out"
        exit 1
    fi
    echo "Verified $name ($actual)"
}

download "UniversalMac_13.2.1_22D68_Restore.ipsw" \
    "https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-48346/EFF99C1E-C408-4E7A-A448-12E1468AF06C/UniversalMac_13.2.1_22D68_Restore.ipsw" \
    "0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04"

download "UniversalMac_11.6_20G165_Restore.ipsw" \
    "https://updates.cdn-apple.com/2021FallFCS/fullrestores/071-97388/C361BF5E-0E01-47E5-8D30-5990BC3C9E29/UniversalMac_11.6_20G165_Restore.ipsw" \
    "9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6"

download "iPad_Pro_A12X_A12Z_14.5_18E199_Restore.ipsw" \
    "https://updates.cdn-apple.com/2021SpringFCS/fullrestores/071-17726/009AB913-7F89-4963-8BF1-003B5D0076EC/iPad_Pro_A12X_A12Z_14.5_18E199_Restore.ipsw" \
    "e6ac263ae3124aa4ca1424ec9d395b0d798c349e9c31f9964783e1ddf58b1446"

echo "IPSW downloads verified."
