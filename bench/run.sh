#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
messages=${MESSAGES:-1000000}
batch=${BATCH:-256}
warmup=${WARMUP:-100000}
repeats=${REPEATS:-5}
connections=${CONNECTIONS:-8}
objects=${OBJECTS:-64}
latency_messages=${LATENCY_MESSAGES:-10000}
latency_warmup=${LATENCY_WARMUP:-1000}
idle_ms=${IDLE_MS:-1000}
resource_connections=${RESOURCE_CONNECTIONS:-"1 8 32 64"}
resource_warmup=${RESOURCE_WARMUP:-10000}
mode=${1:-throughput}

"$root/bench/build.sh"

echo "# kernel=$(uname -r) libwayland=$(pkg-config --modversion wayland-client) messages=$messages batch=$batch warmup=$warmup" >&2

run_all() {
    "$@" "$root/zig-out/bench/raw-ping" "$messages" "$batch" "$warmup"
    "$@" "$root/zig-out/bench/libwayland-ping" "$messages" "$batch" "$warmup"
    "$@" "$root/zig-out/bench/wayring-ping" "$messages" "$batch" "$warmup"
}

case "$mode" in
    throughput)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample" >&2
            run_all env
            sample=$((sample + 1))
        done
        ;;
    objects)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample objects=$objects" >&2
            "$root/zig-out/bench/libwayland-ping" \
                "$messages" "$batch" "$warmup" 1 round-trip "$objects"
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" 1 round-trip "$objects"
            sample=$((sample + 1))
        done
        ;;
    perf)
        events=task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses
        run_all perf stat -e "$events"
        ;;
    syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        run_all strace -f -c
        ;;
    multi)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample connections=$connections" >&2
            "$root/zig-out/bench/libwayland-ping" \
                "$messages" "$batch" "$warmup" "$connections"
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" "$connections"
            sample=$((sample + 1))
        done
        ;;
    multi-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        strace -f -c "$root/zig-out/bench/libwayland-ping" \
            "$messages" "$batch" "$warmup" "$connections"
        strace -f -c "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" "$connections"
        ;;
    resources)
        for resource_count in $resource_connections; do
            echo "# scope=idle connections=$resource_count idle_ms=$idle_ms" >&2
            "$root/zig-out/bench/libwayland-ping" \
                1 256 "$resource_warmup" "$resource_count" idle 1 "$idle_ms"
            "$root/zig-out/bench/wayring-ping" \
                1 256 "$resource_warmup" "$resource_count" idle 1 "$idle_ms"
        done
        ;;
    idle-perf)
        events=task-clock,context-switches,cpu-migrations,page-faults
        echo "# scope=idle connections=$connections idle_ms=$idle_ms" >&2
        perf stat -e "$events" "$root/zig-out/bench/libwayland-ping" \
            1 1 1 "$connections" idle 1 "$idle_ms"
        perf stat -e "$events" "$root/zig-out/bench/wayring-ping" \
            1 1 1 "$connections" idle 1 "$idle_ms"
        ;;
    latency)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample connections=$connections latency_rounds=$latency_messages" >&2
            "$root/zig-out/bench/libwayland-ping" \
                "$latency_messages" 1 "$latency_warmup" "$connections" latency
            "$root/zig-out/bench/wayring-ping" \
                "$latency_messages" 1 "$latency_warmup" "$connections" latency
            sample=$((sample + 1))
        done
        ;;
    client)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=client-tx" >&2
            "$root/zig-out/bench/libwayland-ping" \
                "$messages" "$batch" "$warmup" 1 client-tx
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" 1 client-tx
            "$root/zig-out/bench/libwayland-ping" \
                "$messages" "$batch" "$warmup" 1 client-rx
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" 1 client-rx
            sample=$((sample + 1))
        done
        ;;
    client-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        strace -f -c "$root/zig-out/bench/libwayland-ping" \
            "$messages" "$batch" "$warmup" 1 client-tx
        strace -f -c "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" 1 client-tx
        strace -f -c "$root/zig-out/bench/libwayland-ping" \
            "$messages" "$batch" "$warmup" 1 client-rx
        strace -f -c "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" 1 client-rx
        ;;
    client-perf)
        events=task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses
        perf stat -e "$events" "$root/zig-out/bench/libwayland-ping" \
            "$messages" "$batch" "$warmup" 1 client-tx
        perf stat -e "$events" "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" 1 client-tx
        perf stat -e "$events" "$root/zig-out/bench/libwayland-ping" \
            "$messages" "$batch" "$warmup" 1 client-rx
        perf stat -e "$events" "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" 1 client-rx
        ;;
    interop)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=mixed-interop" >&2
            "$root/zig-out/bench/wayring-interop" \
                "$messages" "$batch" "$warmup" libwayland-client
            "$root/zig-out/bench/wayring-interop" \
                "$messages" "$batch" "$warmup" libwayland-server
            sample=$((sample + 1))
        done
        ;;
    interop-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        strace -f -c "$root/zig-out/bench/wayring-interop" \
            "$messages" "$batch" "$warmup" libwayland-client
        strace -f -c "$root/zig-out/bench/wayring-interop" \
            "$messages" "$batch" "$warmup" libwayland-server
        ;;
    interop-perf)
        events=task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses
        perf stat -e "$events" "$root/zig-out/bench/wayring-interop" \
            "$messages" "$batch" "$warmup" libwayland-client
        perf stat -e "$events" "$root/zig-out/bench/wayring-interop" \
            "$messages" "$batch" "$warmup" libwayland-server
        ;;
    interop-latency)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=mixed-interop latency_rounds=$latency_messages" >&2
            "$root/zig-out/bench/wayring-interop" \
                "$latency_messages" 1 "$latency_warmup" libwayland-client-latency
            "$root/zig-out/bench/wayring-interop" \
                "$latency_messages" 1 "$latency_warmup" libwayland-server-latency
            sample=$((sample + 1))
        done
        ;;
    xdg-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 xdg-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 xdg-libwayland-server
        ;;
    shm-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 shm-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 shm-libwayland-server
        ;;
    dmabuf-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 dmabuf-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 dmabuf-libwayland-server
        ;;
    data-device-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 data-device-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 data-device-libwayland-server
        ;;
    output-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 output-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 output-libwayland-server
        ;;
    pointer-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 pointer-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 pointer-libwayland-server
        ;;
    keyboard-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 keyboard-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 keyboard-libwayland-server
        ;;
    *)
        echo "usage: $0 [throughput|objects|perf|syscalls|multi|multi-syscalls|resources|idle-perf|latency|client|client-perf|client-syscalls|interop|interop-perf|interop-syscalls|interop-latency|xdg-interop|shm-interop|dmabuf-interop|data-device-interop|output-interop|pointer-interop|keyboard-interop]" >&2
        exit 2
        ;;
esac
