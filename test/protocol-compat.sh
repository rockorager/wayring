#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scanner=$1
wayland_source=$2
protocols_source=$3
temporary=$(mktemp -d)
generated="$temporary/standard.zig"
trap 'rm -rf "$temporary"' EXIT

"$scanner" \
    "$wayland_source/protocol/wayland.xml" \
    "$protocols_source/stable/xdg-shell/xdg-shell.xml" \
    "$protocols_source/stable/presentation-time/presentation-time.xml" \
    "$protocols_source/stable/linux-dmabuf/linux-dmabuf-v1.xml" \
    "$generated"
zig fmt "$generated" >/dev/null
zig test -OReleaseSafe \
    --dep wayring --dep standard_protocols \
    -Mroot="$root/test/standard-protocols.zig" \
    --dep wayring -Mstandard_protocols="$generated" \
    -Mwayring="$root/src/root.zig"

find "$protocols_source/stable" \
    "$protocols_source/staging" \
    "$protocols_source/unstable" \
    "$protocols_source/experimental" \
    -type f -name '*.xml' | sort | while IFS= read -r protocol; do
    "$scanner" "$wayland_source/protocol/wayland.xml" \
        "$protocol" "$temporary/corpus.zig"
    zig fmt "$temporary/corpus.zig" >/dev/null
done
