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
bench/run.sh xdg-interop
bench/run.sh data-device-interop
```

Configure a run through environment variables:

```sh
MESSAGES=5000000 BATCH=256 WARMUP=200000 REPEATS=10 bench/run.sh throughput
CONNECTIONS=32 MESSAGES=100000 bench/run.sh multi
OBJECTS=64 MESSAGES=5000000 bench/run.sh objects
CONNECTIONS=8 LATENCY_MESSAGES=10000 LATENCY_WARMUP=1000 bench/run.sh latency
RESOURCE_CONNECTIONS="1 8 32 64" IDLE_MS=1000 bench/run.sh resources
CONNECTIONS=64 IDLE_MS=5000 bench/run.sh idle-perf
```

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
pool and buffer construction, synchronization, and ordered destruction. This
exercises production FD ownership and nested core object lifecycles in both
directions.

Linux-dmabuf interoperability mode runs both a libwayland client against a
Wayring server and a Wayring client against a libwayland server. Each pairing
performs version-3 modifier advertisement, params construction, close-on-exec
plane FD transfer, immediate and asynchronous `wl_buffer` creation, nonfatal
import failure, synchronization, and ordered destruction. The harness validates
wire and object semantics without attempting to import the synthetic descriptor
as a real GPU dma-buf.

Data-device interoperability mode drives a real libwayland clipboard source
against a Wayring server. It binds a seat and data-device manager, creates a
source and device, advertises a MIME type, sets the selection, transfers the
payload through a close-on-exec pipe supplied by the server, and validates
ordered source, device, and seat teardown.
