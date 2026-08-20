#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
messages=${MESSAGES:-1000000}
batch=${BATCH:-256}
warmup=${WARMUP:-100000}
repeats=${REPEATS:-5}
connections=${CONNECTIONS:-8}
latency_messages=${LATENCY_MESSAGES:-10000}
latency_warmup=${LATENCY_WARMUP:-1000}
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
    *)
        echo "usage: $0 [throughput|perf|syscalls|multi|multi-syscalls|latency|client|client-perf|client-syscalls|interop|interop-perf|interop-syscalls|interop-latency]" >&2
        exit 2
        ;;
esac
