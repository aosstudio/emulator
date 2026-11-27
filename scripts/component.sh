#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
component=$1
case "$component" in
    qt | netsim | graphics | firmware | package) ;;
    *) printf 'Unknown component %s\n' "$component" >&2; exit 2 ;;
esac
mkdir -p out/components
case "$(findmnt -n -o FSTYPE -T out)" in
    tmpfs | ramfs) printf 'Use a disk-backed build directory.\n' >&2; exit 1 ;;
esac
export EMU_WORK TMPDIR
EMU_WORK=$(mktemp -d "$root/out/$component.XXXXXXXX")
TMPDIR="$EMU_WORK/tmp"
mkdir -p "$TMPDIR"
printf 'Component work directory: %s\n' "$EMU_WORK"
exec flock "out/$component.lock" bash "scripts/build-$component.sh"
