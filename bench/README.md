# Transport benchmarks

The benchmark sends a private 12-byte Wayland `ping(uint)` request from one
process to another and waits for one `pong(uint)` after each phase. The raw
Unix-stream implementation is a lower-bound control; libwayland measures its
normal generated stub, buffering, marshalling, event-loop, and dispatch path.
The `wayring-multishot` backend uses io_uring `sendmsg` and a persistent
multishot `recvmsg` with a provided-buffer ring. It validates every frame and
directly decodes and dispatches its integer argument. Responses use the
generated direct-to-TX encoder, which reserves shared blocks and avoids an
intermediate frame copy. The receive path retains
the ancillary-data layout needed for SCM_RIGHTS rather than substituting plain
`recv` for easier benchmark numbers. Before timing, it sends a real descriptor
through SCM_RIGHTS, queues it on the receiver's ordered FD lane, and verifies
that it arrived with close-on-exec set. The server runs through the bounded
connection actor and generation-checked CQE dispatcher, coalesces queued output
behind a single active send SQE, and cancels its multishot receive before
unregistering buffers.

Build with `zig build benchmarks`, or run all three implementations directly:

```sh
bench/run.sh throughput
bench/run.sh objects
bench/run.sh perf
bench/run.sh syscalls
bench/run.sh multi
bench/run.sh multi-syscalls
bench/run.sh rx-pressure
bench/run.sh rx-pressure-syscalls
bench/run.sh rx-pool
bench/run.sh rx-pool-syscalls
bench/run.sh rx-pool-latency
bench/run.sh rx-pool-resources
bench/run.sh fixed-files
bench/run.sh fixed-files-perf
bench/run.sh fixed-files-latency
bench/run.sh resources
bench/run.sh idle-perf
bench/run.sh latency
bench/run.sh client
bench/run.sh client-perf
bench/run.sh client-syscalls
bench/run.sh interop
bench/run.sh interop-perf
bench/run.sh interop-syscalls
bench/run.sh interop-latency
bench/run.sh server-driver
bench/run.sh server-driver-latency
bench/run.sh client-driver
bench/run.sh client-driver-latency
bench/run.sh xdg-interop
bench/run.sh data-device-interop
bench/run.sh output-interop
bench/run.sh pointer-interop
bench/run.sh keyboard-interop
bench/run.sh touch-interop
bench/run.sh subsurface-interop
bench/run.sh shm
bench/run.sh shm-perf
bench/run.sh shm-syscalls
bench/run.sh viewport
```

Configure a run through environment variables:

```sh
MESSAGES=5000000 BATCH=256 WARMUP=200000 REPEATS=10 bench/run.sh throughput
CONNECTIONS=32 MESSAGES=100000 bench/run.sh multi
OBJECTS=64 MESSAGES=5000000 bench/run.sh objects
CONNECTIONS=8 LATENCY_MESSAGES=10000 LATENCY_WARMUP=1000 bench/run.sh latency
RESOURCE_CONNECTIONS="1 8 32 64" IDLE_MS=1000 bench/run.sh resources
CONNECTIONS=64 IDLE_MS=5000 bench/run.sh idle-perf
SHM_SIZES="4096 65536 8294400" SHM_BATCHES="1 16" bench/run.sh shm
```

SHM mode compares the shrink-sealed zero-copy pin path, ordinary and nested
SIGBUS-guarded scopes, and the io_uring copy path. The sealed result measures
mapping acquisition and endpoint sampling rather than memory-copy bandwidth;
its reported byte rate is effective buffer availability. Guarded and nested
modes reuse one pin and measure access/end plus endpoint sampling, not pin
acquisition or memory bandwidth.
Nested mode holds one outer scope across the run; `batch` does not affect these
two scope-only modes. Copy mode moves every reported byte into caller-owned
memory. `SHM_TARGET_BYTES` controls work per matrix cell and
`SHM_MAX_WORKING_BYTES` caps `size * batch` destination storage. Perf and syscall
modes use `SHM_SIZE`, `SHM_BATCH`, `SHM_OPERATIONS`, and `SHM_WARMUP`.

The contention benchmark compares one and two threads, each with its own store,
using five samples of 100,000 scopes per thread. Setup is outside timing; thread
join is included. It reports aggregate nanoseconds per scope, not per-thread
latency. Run it with both modules optimized:

```sh
zig test -O ReleaseFast --dep wayring -Mroot=bench/shm.zig \
    -O ReleaseFast -Mwayring=src/root.zig \
    --test-filter 'guarded access contention benchmark'
```

Viewport mode sends the same three real protocol requests per operation from
the same libwayland client: `set_source`, `set_destination`, and
`wl_surface.commit`. It alternates a libwayland server with a Wayring server and
uses one sync round trip per `BATCH`. The libwayland handler validates values
and ordering; the Wayring handler performs equivalent request-value and order
validation so the result compares core transport and generated dispatch.

The multi-connection modes compare Wayring and libwayland across identical
socket counts and messages per connection. Wayring uses one io_uring instance
in each process across all socket pairs. Every server multishot receive selects
from one provided-buffer group sized to at least one buffer per connection, and
all connection actors share the fragment and transmit pools. Server object
dispatch also uses one shared physical node pool with connection-scoped
namespaces. `MESSAGES` and `WARMUP` are per
connection; the reported message count and throughput are aggregate. Wayring
client send SQEs for every connection are submitted together once per batch;
libwayland queues the same requests before flushing each display. Connection
counts are limited to 64.

Receive-pressure mode deliberately gives all Wayring connections only two
shared provided buffers. It compares immediate `ENOBUFS` rearming against the
allocation-free deferred FIFO using identical traffic. The syscall variant is
the decisive check for avoided retry submissions; timing remains useful for
detecting scheduler overhead but is sensitive to host scheduling.
The `rx-pool` modes vary both connection and shared-buffer counts to locate the
memory, throughput, syscall, and all-client tail-latency knee. Configure their
matrix with `RX_CONNECTIONS="8 16 32"` and `RX_BUFFERS="2 4 8 16"`. Output
includes exact reserved receive-pool capacity because process RSS is generally
too coarse and noisy to distinguish these 64 KiB buffer-count increments.

Fixed-file modes compare ordinary socket descriptors with a slot-aligned
registered-file table used by both benchmark processes. Registration time is
reported separately and excluded from message throughput and latency. Configure
the throughput and latency matrix with `FIXED_CONNECTIONS="8 32 64"`. Samples
alternate execution order to avoid systematically favoring the first mode.

Resource mode samples initialized client/server pairs while idle and again
after `RESOURCE_WARMUP` messages per connection. It reports the resident memory
of each process, their combined RSS, and server RSS per connection. The active
sample captures lazily committed working memory that idle RSS intentionally
does not. Fixed process and shared-library cost is included, so compare the
slope across `RESOURCE_CONNECTIONS`, not only the per-connection quotient.
Compare server RSS between implementations: the Wayring parent is a minimal
io_uring benchmark driver while the libwayland parent uses a full client, so
their client and combined RSS figures describe each executable but are not
client-runtime parity measurements.
`idle-perf` records task-clock and scheduler counters for the whole process tree
during the same idle interval. Context switches are the portable wakeup proxy;
the resource output also reports their exact per-process deltas from `/proc`
because some environments restrict perf's kernel counters. The benchmark does
not label context switches as exact kernel wakeup counts.

Object mode binds or installs multiple instances of the benchmark interface and
round-robins requests across them. This defeats Wayring's last-object lookup
cache and measures object-table dispatch rather than repeatedly targeting one
hot resource. Resource setup is excluded from timing; object counts are limited
to 64.

Client transmit mode isolates request encoding, buffering, and socket output
from server protocol dispatch. Each implementation sends generated `ping`
requests to a raw peer that only drains and acknowledges the exact wire-byte
count for each phase. The acknowledgement is included in the timing so a fast
client cannot report bytes that remain buffered after the sample. Wayring uses
its generated direct encoder, shared TX blocks, persistent reactor send state,
and io_uring submission; libwayland uses its generated client stub and normal
blocking flush path. Setup traffic and allocator initialization occur before
the warmup and timed phases.

Client receive mode reverses the setup: a raw peer writes complete generated
`pong` events, and the timed client validates object metadata, frames each
message, decodes the typed event, and invokes its handler. Wayring exercises
the production multishot receiver, provided-buffer ring, connection actor,
namespace, and generic event dispatcher. Libwayland uses its normal display
dispatch and generated listener. The peer waits at phase boundaries, excluding
setup and warmup traffic from the sample.

Latency mode measures complete ping/pong rounds and reports mean, p50, p95,
p99, and maximum nanoseconds. With one connection this is normal round-trip
latency. With multiple connections each round sends one ping to every socket
and ends only after every pong is dispatched, so the distribution measures
all-client round latency rather than claiming to measure independent one-way
latencies. Setup and `LATENCY_WARMUP` rounds are excluded.

`perf` records CPU, scheduling, page-fault, and hardware-counter metrics for
the process tree. `syscalls` uses `strace -f -c` to report syscall counts and
must not be used for timing comparisons because tracing changes execution.
Syscall totals include process setup and warmup; use a large message count so
those fixed costs become negligible. Throughput mode defaults to five
interleaved raw/libwayland/Wayring samples.

Mixed interoperability mode runs both pairings: a libwayland client against a
Wayring server and a Wayring client against a libwayland server. Both complete
the normal display registry round trip, advertise and bind the private global,
apply callback destruction and `delete_id`, and then exchange typed generated
requests and events. Before timing, each pairing also transfers an eventfd in
both directions through generated `fd` arguments and verifies close-on-exec.
The measurements are useful for validating real wire
compatibility and finding asymmetric runtime costs; they are not a direct
replacement for the symmetric implementation comparisons above.

Server-driver modes isolate the allocation-free batched `server.Driver` from
the prior handwritten one-client CQE loop while keeping the same libwayland
client, generated protocol handler, traffic, and ring configuration. Samples
alternate order, and registration/setup remain outside timed traffic.

Client-driver modes make the equivalent comparison for `client.Driver` against
the handwritten Wayring-client CQE loop, using the same libwayland server,
generated request/event path, traffic, and alternating sample order.

Xdg interoperability mode drives both a real libwayland client against a
Wayring server and a Wayring client against a real libwayland server. Each
pairing performs registry binding, `wl_compositor` surface creation,
`xdg_wm_base` ping/pong, `xdg_surface` and `xdg_toplevel` construction,
configure/ack, presentation clock advertisement, presented and discarded
feedback, synchronization, and ordered destruction. Presentation feedback also
validates destructor events, `delete_id`, and immediate client-ID reuse. This
validates production protocol object and version lifecycles independently of
the private benchmark protocol.

Shm interoperability mode runs both a libwayland client against a Wayring
server and a Wayring client against a libwayland server. Each pairing performs
`wl_shm` format advertisement, close-on-exec shared-memory descriptor transfer,
pool and buffer construction, surface attachment, surface- and buffer-coordinate
damage, opaque and input region geometry, buffer transform and scale, surface
offset, frame completion, commit, buffer release, synchronization, and ordered
destruction. The Wayring server validates request values, ordering, generated
object construction, and event delivery without embedding compositor policy.
This exercises production FD ownership, asynchronous presentation, and nested
core object lifecycles in both directions.

Linux-dmabuf interoperability mode runs both a libwayland client against a
Wayring server and a Wayring client against a libwayland server. Each pairing
performs version-3 modifier advertisement, params construction, close-on-exec
plane FD transfer, immediate and asynchronous `wl_buffer` creation, nonfatal
import failure, synchronization, and ordered destruction. The harness validates
wire and object semantics without attempting to import the synthetic descriptor
as a real GPU dma-buf.

Data-device interoperability mode runs both library pairings. It binds a seat
and data-device manager, creates a source and device, advertises a MIME type,
sets the selection, negotiates source and preferred actions, and starts a drag
with origin and icon surfaces. Each server also creates a destination offer,
sends enter, motion, drop, and leave events, and transfers both source and offer
payloads through close-on-exec pipes. Both paths validate drag completion,
descriptor ownership, and ordered offer, source, device, surface, and seat
teardown.

Output interoperability mode runs both library pairings. A version-4 output
publishes geometry, mode flags, scale, stable name, description, and `done` in
one event burst. Both clients validate every field before releasing the output,
covering version-gated core events and output-resource teardown.

Pointer interoperability mode runs both library pairings. Each advertises seat
capabilities and name, creates a surface and pointer, and validates focus,
fixed-point motion, button, wheel source, axis, discrete and value120 scroll
data, stop, and frame events before ordered pointer, surface, and seat teardown.

Keyboard interoperability mode runs both library pairings. Each advertises seat
capabilities and name, creates a surface and keyboard, transfers a close-on-exec
XKB keymap FD, and validates pressed-key arrays, focus, modifiers, key state,
repeat metadata, and leave before ordered keyboard, surface, and seat teardown.

Touch interoperability mode runs both library pairings. Each creates a surface
and touch object, then validates contact down, motion, shape, orientation, frame,
up, and cancellation semantics before ordered touch, surface, and seat teardown.

Subsurface interoperability mode runs both library pairings. Each constructs a
parent and child surface and exercises position, stacking, synchronization,
desynchronization, commits, and ordered subsurface, surface, and subcompositor
teardown. The Wayring side checks generated request values and ordering; role
and scene-graph semantics belong to the compositor.

Legacy-shell interoperability mode runs both library pairings against the core
`wl_shell` protocol. It assigns a shell-surface role, exchanges ping/pong,
configure, and popup completion events, and validates title, class, toplevel,
and surface teardown. This closes core protocol coverage while modern clients
remain expected to use xdg-shell.
