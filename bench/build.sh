#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/zig-out/bench"
generated="$out/generated"
wayland_datadir=$(pkg-config --variable=pkgdatadir wayland-client)
mkdir -p "$generated"

zig build-exe -OReleaseSafe --dep wayring \
    -Mroot="$root/tools/wayring-scanner.zig" \
    -Mwayring="$root/src/root.zig" \
    -femit-bin="$out/wayring-scanner"
"$out/wayring-scanner" "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark.zig"
"$out/wayring-scanner" "$wayland_datadir/wayland.xml" \
    "$generated/wayland-core.zig"

wayland-scanner client-header "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-client.h"
wayland-scanner server-header "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-server.h"
wayland-scanner private-code "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-protocol.c"

cflags="-std=c11 -O3 -DNDEBUG -D_GNU_SOURCE -Wall -Wextra -Werror"

# shellcheck disable=SC2086
cc $cflags -I"$generated" \
    $(pkg-config --cflags wayland-client wayland-server) \
    "$root/bench/libwayland-client.c" \
    "$root/bench/libwayland-server.c" \
    "$generated/wayring-benchmark-protocol.c" \
    $(pkg-config --libs wayland-client wayland-server) \
    -o "$out/libwayland-ping"

# shellcheck disable=SC2086
cc $cflags "$root/bench/raw.c" -o "$out/raw-ping"

zig build-exe -OReleaseFast -lc --dep wayring --dep benchmark_protocol \
    -Mroot="$root/bench/wayring.zig" \
    --dep wayring -Mbenchmark_protocol="$generated/wayring-benchmark.zig" \
    -Mwayring="$root/src/root.zig" \
    -femit-bin="$out/wayring-ping"

# Keep libwayland out of the normal Wayring executable so mixed-interoperability
# coverage cannot perturb its code layout or benchmark results.
# shellcheck disable=SC2086
zig build-exe -OReleaseFast -lc --dep wayring --dep core_protocol --dep benchmark_protocol \
    -I"$root/bench" -I"$generated" \
    -Mroot="$root/bench/interop.zig" \
    -cflags $cflags -DWAYRING_PEER_ONLY -I"$generated" \
    $(pkg-config --cflags wayland-client wayland-server) -- \
    "$root/bench/libwayland-client.c" \
    "$root/bench/libwayland-server.c" \
    "$generated/wayring-benchmark-protocol.c" \
    --dep wayring -Mcore_protocol="$generated/wayland-core.zig" \
    --dep wayring -Mbenchmark_protocol="$generated/wayring-benchmark.zig" \
    -Mwayring="$root/src/root.zig" \
    $(pkg-config --libs wayland-client wayland-server) \
    -femit-bin="$out/wayring-interop"
