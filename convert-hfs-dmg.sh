#!/usr/bin/env bash
#
# convert-hfs-dmg.sh — convert an HFS .dmg to an HFS+ .dmg using impluse-hfs.
#
# impluse-hfs reads a *flat* byte stream; it can't decode UDIF/compressed .dmg
# containers (it would silently read garbage past the first region). This script
# wraps the safe pipeline:
#
#   1. hdiutil convert  : decode the source .dmg to a flat raw image
#   2. impluse-hfs       : convert the flat HFS image to a flat HFS+ image
#   3. hdiutil convert  : repackage the flat HFS+ image as a compressed .dmg
#
# Usage:  convert-hfs-dmg.sh <source.dmg> <destination.dmg>
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
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

format=${FORMAT:-UDZO}

echo "==> Decoding source to a flat image…"
# UDTO produces a raw track image; hdiutil appends .cdr to the -o name.
hdiutil convert "$SRC" -format UDTO -o "$work/flat" >/dev/null
flat="$work/flat.cdr"

echo "==> Converting HFS → HFS+ with impluse-hfs…"
"$impluse" convert "$flat" "$work/out.raw"

echo "==> Repackaging as a $format disk image…"
# The impluse output is a bare HFS+ volume with no partition map, so tell
# hdiutil the input is a raw disk image.
hdiutil convert "$work/out.raw" -format "$format" \
	-srcimagekey diskimage-class=CRawDiskImage \
	-o "$work/result" >/dev/null
# hdiutil appends .dmg; move it to exactly the requested destination path.
mv "$work/result.dmg" "$DST"

echo "==> Done: $DST"
