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
rx_connections=${RX_CONNECTIONS:-"8 16 32"}
rx_buffers=${RX_BUFFERS:-"2 4 8 16"}
fixed_connections=${FIXED_CONNECTIONS:-"8 32 64"}
shm_sizes=${SHM_SIZES:-"4096 65536 8294400 33177600"}
shm_batches=${SHM_BATCHES:-"1 16"}
shm_target_bytes=${SHM_TARGET_BYTES:-1073741824}
shm_max_working_bytes=${SHM_MAX_WORKING_BYTES:-268435456}
mode=${1:-throughput}

(cd "$root" && zig build benchmarks)

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
    rx-pressure)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample connections=$connections buffers=2" >&2
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" "$connections" rx-pressure-immediate
            "$root/zig-out/bench/wayring-ping" \
                "$messages" "$batch" "$warmup" "$connections" rx-pressure-deferred
            sample=$((sample + 1))
        done
        ;;
    rx-pressure-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        strace -f -c "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" "$connections" rx-pressure-immediate
        strace -f -c "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" "$connections" rx-pressure-deferred
        ;;
    rx-pool)
        for rx_connection_count in $rx_connections; do
            for rx_buffer_count in $rx_buffers; do
                sample=1
                while [ "$sample" -le "$repeats" ]; do
                    echo "# sample=$sample connections=$rx_connection_count buffers=$rx_buffer_count" >&2
                    "$root/zig-out/bench/wayring-ping" \
                        "$messages" "$batch" "$warmup" "$rx_connection_count" \
                        rx-pressure-deferred 1 1000 "$rx_buffer_count"
                    sample=$((sample + 1))
                done
            done
        done
        ;;
    rx-pool-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        for rx_connection_count in $rx_connections; do
            for rx_buffer_count in $rx_buffers; do
                echo "# connections=$rx_connection_count buffers=$rx_buffer_count" >&2
                strace -f -c "$root/zig-out/bench/wayring-ping" \
                    "$messages" "$batch" "$warmup" "$rx_connection_count" \
                    rx-pressure-deferred 1 1000 "$rx_buffer_count"
            done
        done
        ;;
    rx-pool-latency)
        for rx_connection_count in $rx_connections; do
            for rx_buffer_count in $rx_buffers; do
                echo "# connections=$rx_connection_count buffers=$rx_buffer_count latency_rounds=$latency_messages" >&2
                "$root/zig-out/bench/wayring-ping" \
                    "$latency_messages" 1 "$latency_warmup" "$rx_connection_count" \
                    rx-pool-latency 1 1000 "$rx_buffer_count"
            done
        done
        ;;
    rx-pool-resources)
        for rx_connection_count in $rx_connections; do
            for rx_buffer_count in $rx_buffers; do
                echo "# connections=$rx_connection_count buffers=$rx_buffer_count pool_bytes=$((rx_buffer_count * 65536)) idle_ms=$idle_ms" >&2
                "$root/zig-out/bench/wayring-ping" \
                    1 1 "$resource_warmup" "$rx_connection_count" \
                    rx-pool-idle 1 "$idle_ms" "$rx_buffer_count"
            done
        done
        ;;
    fixed-files)
        for fixed_connection_count in $fixed_connections; do
            sample=1
            while [ "$sample" -le "$repeats" ]; do
                echo "# sample=$sample connections=$fixed_connection_count" >&2
                if [ $((sample % 2)) -eq 1 ]; then
                    "$root/zig-out/bench/wayring-ping" \
                        "$messages" "$batch" "$warmup" "$fixed_connection_count"
                    "$root/zig-out/bench/wayring-ping" \
                        "$messages" "$batch" "$warmup" "$fixed_connection_count" fixed-files
                else
                    "$root/zig-out/bench/wayring-ping" \
                        "$messages" "$batch" "$warmup" "$fixed_connection_count" fixed-files
                    "$root/zig-out/bench/wayring-ping" \
                        "$messages" "$batch" "$warmup" "$fixed_connection_count"
                fi
                sample=$((sample + 1))
            done
        done
        ;;
    fixed-files-perf)
        events=task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses
        perf stat -e "$events" "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" "$connections"
        perf stat -e "$events" "$root/zig-out/bench/wayring-ping" \
            "$messages" "$batch" "$warmup" "$connections" fixed-files
        ;;
    fixed-files-latency)
        for fixed_connection_count in $fixed_connections; do
            sample=1
            while [ "$sample" -le "$repeats" ]; do
                echo "# sample=$sample connections=$fixed_connection_count latency_rounds=$latency_messages" >&2
                if [ $((sample % 2)) -eq 1 ]; then
                    "$root/zig-out/bench/wayring-ping" \
                        "$latency_messages" 1 "$latency_warmup" "$fixed_connection_count" latency
                    "$root/zig-out/bench/wayring-ping" \
                        "$latency_messages" 1 "$latency_warmup" "$fixed_connection_count" \
                        fixed-files-latency
                else
                    "$root/zig-out/bench/wayring-ping" \
                        "$latency_messages" 1 "$latency_warmup" "$fixed_connection_count" \
                        fixed-files-latency
                    "$root/zig-out/bench/wayring-ping" \
                        "$latency_messages" 1 "$latency_warmup" "$fixed_connection_count" latency
                fi
                sample=$((sample + 1))
            done
        done
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
    server-driver)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=server-driver" >&2
            if [ $((sample % 2)) -eq 1 ]; then
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-client
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-client-driver
            else
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-client-driver
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-client
            fi
            sample=$((sample + 1))
        done
        ;;
    server-driver-latency)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=server-driver latency_rounds=$latency_messages" >&2
            if [ $((sample % 2)) -eq 1 ]; then
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-client-latency
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-client-driver-latency
            else
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-client-driver-latency
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-client-latency
            fi
            sample=$((sample + 1))
        done
        ;;
    client-driver)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=client-driver" >&2
            if [ $((sample % 2)) -eq 1 ]; then
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-server
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-server-driver
            else
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-server-driver
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" libwayland-server
            fi
            sample=$((sample + 1))
        done
        ;;
    client-driver-latency)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=client-driver latency_rounds=$latency_messages" >&2
            if [ $((sample % 2)) -eq 1 ]; then
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-server-latency
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-server-driver-latency
            else
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-server-driver-latency
                "$root/zig-out/bench/wayring-interop" \
                    "$latency_messages" 1 "$latency_warmup" libwayland-server-latency
            fi
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
    shm)
        for shm_size in $shm_sizes; do
            shm_operations=$((shm_target_bytes / shm_size))
            if [ "$shm_operations" -lt 32 ]; then shm_operations=32; fi
            shm_warmup=$((shm_operations / 10))
            if [ "$shm_warmup" -lt 1 ]; then shm_warmup=1; fi
            for shm_batch in $shm_batches; do
                if [ $((shm_size * shm_batch)) -gt "$shm_max_working_bytes" ]; then
                    continue
                fi
                sample=1
                while [ "$sample" -le "$repeats" ]; do
                    echo "# sample=$sample scope=shm size=$shm_size batch=$shm_batch operations=$shm_operations" >&2
                    "$root/zig-out/bench/wayring-shm" \
                        sealed "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
                    "$root/zig-out/bench/wayring-shm" \
                        copy "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
                    sample=$((sample + 1))
                done
            done
        done
        ;;
    shm-perf)
        events=task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses
        shm_size=${SHM_SIZE:-65536}
        shm_batch=${SHM_BATCH:-16}
        shm_operations=${SHM_OPERATIONS:-$((shm_target_bytes / shm_size))}
        shm_warmup=${SHM_WARMUP:-$((shm_operations / 10))}
        perf stat -e "$events" "$root/zig-out/bench/wayring-shm" \
            sealed "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
        perf stat -e "$events" "$root/zig-out/bench/wayring-shm" \
            copy "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
        ;;
    shm-syscalls)
        echo "warning: strace perturbs timing; use this mode only for syscall counts" >&2
        shm_size=${SHM_SIZE:-65536}
        shm_batch=${SHM_BATCH:-16}
        shm_operations=${SHM_OPERATIONS:-$((shm_target_bytes / shm_size))}
        shm_warmup=${SHM_WARMUP:-$((shm_operations / 10))}
        strace -f -c "$root/zig-out/bench/wayring-shm" \
            sealed "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
        strace -f -c "$root/zig-out/bench/wayring-shm" \
            copy "$shm_size" "$shm_operations" "$shm_batch" "$shm_warmup"
        ;;
    viewport)
        sample=1
        while [ "$sample" -le "$repeats" ]; do
            echo "# sample=$sample scope=viewport" >&2
            if [ $((sample % 2)) -eq 1 ]; then
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" viewport-libwayland
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" viewport-libwayland-client
            else
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" viewport-libwayland-client
                "$root/zig-out/bench/wayring-interop" \
                    "$messages" "$batch" "$warmup" viewport-libwayland
            fi
            sample=$((sample + 1))
        done
        "$root/zig-out/bench/wayring-interop" \
            "$messages" "$batch" "$warmup" viewport-state
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
    touch-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 touch-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 touch-libwayland-server
        ;;
    subsurface-interop)
        "$root/zig-out/bench/wayring-interop" 1 1 1 subsurface-libwayland-client
        "$root/zig-out/bench/wayring-interop" 1 1 1 subsurface-libwayland-server
        ;;
    *)
        echo "usage: $0 [throughput|objects|perf|syscalls|multi|multi-syscalls|resources|idle-perf|latency|client|client-perf|client-syscalls|interop|interop-perf|interop-syscalls|interop-latency|shm|shm-perf|shm-syscalls|viewport|xdg-interop|shm-interop|dmabuf-interop|data-device-interop|output-interop|pointer-interop|keyboard-interop|touch-interop|subsurface-interop]" >&2
        exit 2
        ;;
esac
