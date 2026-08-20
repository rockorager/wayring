#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scanner=$1
wayland_datadir=$(pkg-config --variable=pkgdatadir wayland-client)
protocols_datadir=$(pkg-config --variable=pkgdatadir wayland-protocols)
generated=$(mktemp --suffix=.zig)
trap 'rm -f "$generated"' EXIT

"$scanner" \
    "$wayland_datadir/wayland.xml" \
    "$protocols_datadir/stable/xdg-shell/xdg-shell.xml" \
    "$protocols_datadir/stable/presentation-time/presentation-time.xml" \
    "$protocols_datadir/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml" \
    "$generated"
zig fmt "$generated" >/dev/null
zig test -OReleaseSafe \
    --dep wayring --dep standard_protocols \
    -Mroot="$root/test/standard-protocols.zig" \
    --dep wayring -Mstandard_protocols="$generated" \
    -Mwayring="$root/src/root.zig"
