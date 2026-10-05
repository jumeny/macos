#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${VZ_BUILD_ROOT:-$ROOT/build}"
RELEASE="$BUILD_ROOT/release-roothide"
WORK="$(mktemp -d -t VirtualMac-roothide.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for cmd in dpkg-deb rsync find sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing command: $cmd" >&2; exit 1; }
done

"$SCRIPT_DIR/build-ipad-deb.sh"

SOURCE_DEB="$(find "$BUILD_ROOT/release" -maxdepth 1 -type f -name '*.deb' -print | sort | tail -n 1)"
test -n "$SOURCE_DEB" || { echo "no source deb produced" >&2; exit 1; }

dpkg-deb -R "$SOURCE_DEB" "$WORK/pkg"
mkdir -p "$RELEASE"

# RootHide packages are rooted directly at the randomized jbroot. Never encode
# the current .jbroot-<random> directory in the package.
if test -d "$WORK/pkg/var/jb"; then
  rsync -a "$WORK/pkg/var/jb/" "$WORK/pkg/"
  rm -rf "$WORK/pkg/var/jb"
fi

# Keep the large Virtual Mac runtime inside jbroot/User/Library. User-created
# VM data stays in /var/mobile/Media/VirtualMac and survives package removal.
if test -d "$WORK/pkg/var/root/VirtualMac"; then
  mkdir -p "$WORK/pkg/User/Library"
  mv "$WORK/pkg/var/root/VirtualMac" "$WORK/pkg/User/Library/VirtualMac"
  rmdir "$WORK/pkg/var/root" 2>/dev/null || true
  rmdir "$WORK/pkg/var" 2>/dev/null || true
fi

# Package maintainer scripts must resolve the randomized jbroot at install
# time. RootHide documents jbroot as the supported shell path resolver.
for script in preinst postinst prerm postrm; do
  file="$WORK/pkg/DEBIAN/$script"
  test -f "$file" || continue
  sed -i.bak \
    's#/var/jb#\$JBROOT#g; s#/var/root/VirtualMac#\$JBROOT/User/Library/VirtualMac#g' \
    "$file"
  rm -f "$file.bak"
  sed -i.bak '1a\
JBROOT="$(jbroot / 2>/dev/null || true)"\
if test -z "$JBROOT"; then\
    echo "Virtual Mac: unable to resolve RootHide jbroot" >&2\
    exit 1\
fi\
export JBROOT' "$file"
  rm -f "$file.bak"
  chmod 755 "$file"
done

sed -i.bak 's/^Architecture: .*/Architecture: iphoneos-arm64e/' "$WORK/pkg/DEBIAN/control"
rm -f "$WORK/pkg/DEBIAN/control.bak"

SIZE="$(du -sk "$WORK/pkg" | awk '{print $1}')"
sed -i.bak "s/^Installed-Size: .*/Installed-Size: $SIZE/" "$WORK/pkg/DEBIAN/control"
rm -f "$WORK/pkg/DEBIAN/control.bak"

VERSION="$(sed -n 's/^Version: //p' "$WORK/pkg/DEBIAN/control")"
OUT="$RELEASE/VirtualMac-RootHide-${VERSION}.deb"
rm -f "$OUT"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$OUT"
dpkg-deb --info "$OUT"
echo "RootHide package built: $OUT"
