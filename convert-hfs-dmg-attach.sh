#!/usr/bin/env bash
#
# convert-hfs-dmg-attach.sh — convert an HFS .dmg to an HFS+ .dmg using impluse-hfs.
#
# Same goal as convert-hfs-dmg.sh, but instead of decoding the source to a flat
# file on disk, it attaches the source image (without mounting) so macOS exposes
# a decoded raw device, and impluse-hfs reads straight from that device. This
# avoids writing a full-size flat copy of the source to /tmp.
#
#   1. hdiutil attach -nomount : expose the source as a raw /dev/diskN
#   2. impluse-hfs              : convert the device to a flat HFS+ image
#   3. hdiutil convert          : repackage the flat HFS+ image as a compressed .dmg
#
# Usage:  convert-hfs-dmg-attach.sh <source.dmg> <destination.dmg>
#
# Environment overrides:
#   IMPLUSE   path to the impluse-hfs binary (default: auto-detected)
#   FORMAT    output dmg format passed to hdiutil (default: UDZO; e.g. UDBZ, UDRW)
#
set -euo pipefail

usage() {
	echo "usage: $(basename "$0") <source.dmg> <destination.dmg>" >&2
	exit 2
}

[ "$#" -eq 2 ] || usage
SRC=$1
DST=$2

[ -f "$SRC" ] || { echo "error: source not found: $SRC" >&2; exit 1; }
if [ -e "$DST" ]; then
	echo "error: destination already exists, refusing to overwrite: $DST" >&2
	exit 1
fi

# Locate the impluse-hfs binary.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -n "${IMPLUSE:-}" ]; then
	impluse=$IMPLUSE
elif command -v impluse-hfs >/dev/null 2>&1; then
	impluse=$(command -v impluse-hfs)
elif [ -x "$script_dir/build/Release/impluse-hfs" ]; then
	impluse="$script_dir/build/Release/impluse-hfs"
elif [ -x "$script_dir/impluse-hfs" ]; then
	impluse="$script_dir/impluse-hfs"
else
	echo "error: could not find the impluse-hfs binary." >&2
	echo "       set IMPLUSE=/path/to/impluse-hfs, or build it (build/Release/impluse-hfs)." >&2
	exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/impluse.XXXXXX")
dev=""
cleanup() {
	if [ -n "$dev" ]; then
		hdiutil detach "$dev" >/dev/null 2>&1 || hdiutil detach "$dev" -force >/dev/null 2>&1 || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT

format=${FORMAT:-UDZO}

echo "==> Attaching source (no mount)…"
# Attach read-only without mounting; capture the whole-disk node (e.g. /dev/disk5).
attach_output=$(hdiutil attach -nomount -readonly "$SRC")
dev=$(printf '%s\n' "$attach_output" | grep -oE '/dev/disk[0-9]+' | head -1)
if [ -z "$dev" ]; then
	echo "error: could not determine the attached device node from hdiutil output:" >&2
	printf '%s\n' "$attach_output" >&2
	exit 1
fi
echo "    attached as $dev"

echo "==> Converting HFS → HFS+ with impluse-hfs…"
"$impluse" convert "$dev" "$work/out.raw"

echo "==> Repackaging as a $format disk image…"
# The impluse output is a bare HFS+ volume with no partition map, so tell
# hdiutil the input is a raw disk image.
hdiutil convert "$work/out.raw" -format "$format" \
	-srcimagekey diskimage-class=CRawDiskImage \
	-o "$work/result" >/dev/null
# hdiutil appends .dmg; move it to exactly the requested destination path.
mv "$work/result.dmg" "$DST"

echo "==> Done: $DST"
