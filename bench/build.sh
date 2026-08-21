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
protocols_datadir=$(pkg-config --variable=pkgdatadir wayland-protocols)
xdg_shell="$protocols_datadir/stable/xdg-shell/xdg-shell.xml"
presentation_time="$protocols_datadir/stable/presentation-time/presentation-time.xml"
linux_dmabuf="$protocols_datadir/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml"
"$out/wayring-scanner" "$wayland_datadir/wayland.xml" "$xdg_shell" \
    "$presentation_time" "$linux_dmabuf" \
    "$generated/wayland-xdg.zig"

wayland-scanner client-header "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-client.h"
wayland-scanner server-header "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-server.h"
wayland-scanner private-code "$root/bench/protocol.xml" \
    "$generated/wayring-benchmark-protocol.c"
wayland-scanner client-header "$xdg_shell" \
    "$generated/xdg-shell-client-protocol.h"
wayland-scanner server-header "$xdg_shell" \
    "$generated/xdg-shell-server-protocol.h"
wayland-scanner private-code "$xdg_shell" \
    "$generated/xdg-shell-protocol.c"
wayland-scanner client-header "$presentation_time" \
    "$generated/presentation-time-client-protocol.h"
wayland-scanner server-header "$presentation_time" \
    "$generated/presentation-time-server-protocol.h"
wayland-scanner private-code "$presentation_time" \
    "$generated/presentation-time-protocol.c"
wayland-scanner client-header "$linux_dmabuf" \
    "$generated/linux-dmabuf-client-protocol.h"
wayland-scanner server-header "$linux_dmabuf" \
    "$generated/linux-dmabuf-server-protocol.h"
wayland-scanner private-code "$linux_dmabuf" \
    "$generated/linux-dmabuf-protocol.c"

cflags="-std=c11 -O3 -DNDEBUG -D_GNU_SOURCE -Wall -Wextra -Werror"

# shellcheck disable=SC2086
cc $cflags -I"$generated" \
    $(pkg-config --cflags wayland-client wayland-server) \
    "$root/bench/libwayland-client.c" \
    "$root/bench/libwayland-server.c" \
    "$root/bench/resource.c" \
    "$generated/wayring-benchmark-protocol.c" \
    $(pkg-config --libs wayland-client wayland-server) \
    -o "$out/libwayland-ping"

# shellcheck disable=SC2086
cc $cflags "$root/bench/raw.c" -o "$out/raw-ping"

zig build-exe -OReleaseFast -lc --dep wayring --dep benchmark_protocol \
    -Mroot="$root/bench/wayring.zig" \
    -cflags $cflags -I"$root/bench" -- "$root/bench/resource.c" \
    --dep wayring -Mbenchmark_protocol="$generated/wayring-benchmark.zig" \
    -Mwayring="$root/src/root.zig" \
    -femit-bin="$out/wayring-ping"

# Keep libwayland out of the normal Wayring executable so mixed-interoperability
# coverage cannot perturb its code layout or benchmark results.
# shellcheck disable=SC2086
zig build-exe -OReleaseFast -lc --dep wayring --dep core_protocol --dep standard_protocol --dep benchmark_protocol \
    -I"$root/bench" -I"$generated" \
    -Mroot="$root/bench/interop.zig" \
    -cflags $cflags -DWAYRING_PEER_ONLY -I"$generated" \
    $(pkg-config --cflags wayland-client wayland-server) -- \
    "$root/bench/libwayland-client.c" \
    "$root/bench/libwayland-server.c" \
    "$root/bench/xdg-interop-client.c" \
    "$root/bench/xdg-interop-server.c" \
    "$root/bench/shm-interop-client.c" \
    "$root/bench/shm-interop-server.c" \
    "$root/bench/dmabuf-interop-client.c" \
    "$root/bench/dmabuf-interop-server.c" \
    "$root/bench/data-device-interop-client.c" \
    "$root/bench/data-device-interop-server.c" \
    "$root/bench/output-interop-client.c" \
    "$root/bench/output-interop-server.c" \
    "$root/bench/pointer-interop-client.c" \
    "$root/bench/pointer-interop-server.c" \
    "$root/bench/keyboard-interop-client.c" \
    "$root/bench/keyboard-interop-server.c" \
    "$generated/wayring-benchmark-protocol.c" \
    "$generated/xdg-shell-protocol.c" \
    "$generated/presentation-time-protocol.c" \
    "$generated/linux-dmabuf-protocol.c" \
    --dep wayring -Mcore_protocol="$generated/wayland-core.zig" \
    --dep wayring -Mstandard_protocol="$generated/wayland-xdg.zig" \
    --dep wayring -Mbenchmark_protocol="$generated/wayring-benchmark.zig" \
    -Mwayring="$root/src/root.zig" \
    $(pkg-config --libs wayland-client wayland-server) \
    -femit-bin="$out/wayring-interop"
