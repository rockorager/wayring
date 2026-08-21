# Architecture

## Objective

Wayring is a Linux-only Wayland implementation optimized for throughput,
resource use, and CPU and power efficiency. It preserves the Wayland wire
protocol but deliberately does not preserve libwayland's API or internal
architecture.

Optimizations are accepted only when they beat a conventional nonblocking
Unix-socket baseline under a representative benchmark. Using `io_uring` is a
design constraint, not evidence that a particular ring feature is faster.

## Boundaries

```text
protocol XML -> generated typed codecs -> connection actor -> io_uring reactor
                                            |       |
                                            |       +-- TX queue and backpressure
                                            +---------- RX bytes, FDs, and objects
```

The wire codec has no dependency on `io_uring`. The reactor owns kernel-facing
operations and buffers. A connection actor owns all mutable state for one Unix
stream connection and is never concurrently executed by multiple threads.

## Protocol generation

`wayring-scanner` parses Wayland protocol XML into an allocator-owned
intermediate representation at build time. Generated modules contain concrete
message structs, tagged request/event unions, and direct opcode switches; XML,
reflection, and allocator state never enter the runtime path. Names in the IR
borrow from the source XML while all structural slices follow Zig's explicit
caller-allocator convention.

Generated decoders validate and consume the byte argument stream before
checking the independent descriptor queue. They verify that the complete FD
set is available before transferring any descriptor, so malformed bytes or FD
backpressure cannot partially consume a message's descriptor ownership.
Safe client and server helpers also use generated object-aware decoder variants.
Every non-null `object` argument must exist in that connection's namespace and,
when XML declares an interface, its metadata name must match. These checks run
after byte validation but before descriptor transfer, so an invalid reference
cannot leak an FD carried by the same message. Standalone codec users retain the
policy-free decoder, while safe outgoing helpers validate object references
before committing a frame to TX. Interfaces without object arguments generate
neither the validator nor an alternate hot path.
Generated enum arguments use four-byte transparent wrappers with named values
and explicit integer conversion. Unknown values remain representable and round
trip unchanged, including signed and cross-interface enums; bitfields also
provide zero-cost membership checks.
Generated encoders validate the entire message and calculate its exact frame
size before reserving shared TX blocks. They then write the header and padded
arguments directly across those blocks and atomically commit bytes and FDs;
there is no intermediate frame allocation or queue copy. Untyped `new_id`
arguments expand to their interface string, version, and ID wire fields. The
benchmark protocol uses both generated directions, and the scanner is also
checked against the complete core `wayland.xml` protocol.

Requests containing `new_id` arguments also expose generated transactional
constructors. A constructor validates the parent, creates every child in the
bounded client object namespace, directly encodes the request, and rolls all
children back if any allocation or TX step fails. Typed children inherit the
parent's negotiated version, capped by the child interface maximum; dynamic
children take an explicit interface and version. For typed interfaces declared
by another protocol module, the caller supplies that module's metadata and the
constructor validates its XML interface name before allocating an ID. This
keeps cross-protocol references explicit without runtime reflection or
steady-state allocation.

The server-side counterpart leaves decoding free of application policy, then
admits all decoded `new_id` values in one generated transaction. Applications
supply child contexts and metadata for dynamic or cross-protocol interfaces;
the helper validates interface names and negotiated versions, inserts every
client-selected ID, and removes earlier children if any later insertion fails.
Handlers therefore receive generation-tagged handles without manually
reimplementing multi-object rollback.

Generated events provide the reverse transaction. A server event constructor
allocates every server-range child, directly encodes the event, and cancels all
unpublished children if allocation, validation, or TX backpressure fails. The
client admission helper validates typed and dynamic interface metadata, inserts
every decoded server-range ID, and removes earlier insertions if a later child
cannot be admitted. Typed children inherit the parent object's negotiated
version capped by the child metadata; dynamic events carry an explicit version.
Unpublished server rollback bypasses resource-removal hooks just like failed
request admission, while successfully published children retain normal
lifecycle notification.

Server globals may install a cold-path bind factory. Registry binding first
validates and inserts the requested object, then calls the factory with peer
credentials plus global and resource handles; factory failure cancels the
unpublished insertion. Each client namespace may also install one removal hook
for application resource cleanup. Published destructor removals and disconnect
teardown notify it, while constructor and bind rollback deliberately do not.
The hook lives once per client rather than once per object, preserving object
size and hot lookup locality; disconnect remains O(1) when no hook is installed.
The server runtime may also install one cold-path global-visibility predicate.
Initial registry listings, later global additions and removals, and bind
authorization all apply the same predicate to the client's immutable Linux
credentials and the global definition. Hidden names cannot be bound directly.
Visibility remains stable for each global lifetime so removal publication
matches the clients that observed its addition; policy changes remove and
re-add the global instead of retaining per-registry visibility sets.

Each generated interface also exports compact immutable metadata: its maximum
version and each request/event's introduction version and destructor bit.
Object dispatch resolves the sender ID to an interface and negotiated version,
then rejects unknown or version-ineligible opcodes before typed decoding.

Build and invoke the scanner with:

```sh
zig build
zig-out/bin/wayring-scanner protocol.xml protocol.zig
```

Pass dependency XML files before the output to generate one composed module,
for example `wayland.xml xdg-shell.xml protocols.zig`. Combining dependencies
lets generated extension arguments use the exact enum types declared by core
or other protocols, with duplicate interface names rejected at generation
time.

## Required invariants

- Receive completions are byte-stream fragments, not Wayland frame boundaries.
- Received bytes and `SCM_RIGHTS` descriptors form separate ordered streams.
- At most one receive and one send operation are active per socket direction.
- Object IDs are validated before generated handlers execute.
- Client-created IDs are not reused before `wl_display.delete_id`.
- Every queued or in-flight file descriptor is closed exactly once.
- Failed SQE preparation leaves both the submission queue and operation state
  unchanged, including queued byte and descriptor ownership.
- CQE identities include a connection generation; stale completions never
  dereference recycled connection storage.
- Per-connection byte, descriptor, and object budgets bound resource use.
- A terminal protocol error stops further dispatch before its `wl_display.error`
  event is drained and the connection closes.

Server request dispatch converts malformed input and handler failures into an
ordered terminal `wl_display.error`. Client event dispatch delivers a received
`wl_display.error` to the application, then closes immediately without
dispatching later frames from the same receive batch. Client-side framing,
object lookup, decoding, and handler failures follow the same terminal close
path.

The descriptor stream is represented by a bounded FIFO with explicit
ownership transfer. Receiving SCM_RIGHTS enqueues descriptors in kernel
delivery order; generated decoders pop them only when their message signature
contains an `fd` argument. Teardown and budget failures close every descriptor
still owned by the runtime.

The transmit side stores bytes in reactor-wide fixed-size block chains while
each connection retains a logical byte budget. Enqueue is atomic with respect
to that budget and shared-pool availability. Direct-encoding reservations keep
new blocks private until commit; abort returns them without exposing partial
bytes or taking FD ownership. A send snapshot gathers at most the first two
blocks, only one snapshot may be in flight, and partial completions release
only fully consumed blocks. All descriptors attached to a send are consumed
after its first successful byte. Events generated while that send is active
append to its chain and are coalesced into the next `sendmsg` SQE; a connection
never has two send SQEs active at once.
The connection lifecycle is explicit: `open` accepts dispatch and ordinary
output, `protocol_error` reserves the terminal transition, `draining` permits
only already-queued output and the final error event to send, and `closing`
permits only asynchronous operation teardown. EOF and transport failures enter
`closing` immediately. A failed attempt to queue the protocol error also closes
immediately rather than leaving a half-terminal connection.
Connections occupy generation-tagged reactor slots, so completions from a
closed or reused slot are discarded before actor storage is accessed. Inactive
eight-byte slots are their own intrusive free list, giving connection admission
and recycling O(1) cost without a second allocation or caller-managed indices.
After validation, the hot routed value carries only the four-byte slot/operation
pair; copying the already-validated generation enlarged its return ABI and cost
about two percent in the multi-connection benchmark.

## Allocation policy

Libraries accept a caller-selected `std.mem.Allocator`; they do not select a
hidden global allocator. Each reactor allocates shared pools at initialization,
then message processing performs no allocator calls. Connections retain only
pool indices, queue heads, counters, and logical per-connection budgets.

The provided-buffer ring, receive-fragment blocks, transmit blocks, and
descriptor entries are shared across every connection assigned to a reactor.
Blocks are leased only while a connection has an incomplete frame or queued
output; no connection permanently reserves worst-case backing storage. Slot
release returns all blocks and closes runtime-owned descriptors before the slot
is reused with a new generation.

Receive ancillary-control capacity is configured once per reactor rather than
per peer. Initialization rejects layouts that would leave a provided buffer
without room for the io_uring receive header, control data, and one minimum
Wayland frame.
When every shared provided buffer is selected, the kernel terminates affected
multishot receives with `ENOBUFS`. The actor reports buffer exhaustion without
closing the connection. Callers return already delivered buffers before
rearming inactive peers; repeated rearming while buffers remain held only
produces more `ENOBUFS` completions. The optional reactor-wide deferred-receive
FIFO parks each exhausted peer once. Returning any non-incrementally-consumed
buffer permits one FIFO sweep for a caller-controlled batch submission, and
the permit remains pending if no peer has been parked yet;
`ENOBUFS` alone never permits another sweep. A sweep rather than a buffer-credit
count is required because an already-active multishot receive can race for a
returned buffer, which userspace cannot reserve for a particular rearm SQE.
Pending entries are removed in O(1) on peer destruction, preventing slot reuse
from retaining stale queue links. If one sweep exceeds the available submission
queue space, its pending state survives submission so the caller can continue
the sweep in another batch.
Real-kernel soak coverage retains the whole buffer group across concurrent
clients, then verifies that every stream and transferred descriptor resumes
intact after those buffers are returned.
Pool sizing remains explicit because it is a workload decision, not a function
of admitted connection count. With 32 simultaneously busy benchmark clients,
8 shared 64 KiB buffers retained the throughput plateau, reduced ring-enter
count from 1,182 at 2 buffers to 717, and reduced all-client p99 round latency
from 240 to 186 microseconds. Increasing to 16 buffers saved another 62 enters
but did not improve p99 in that run. Eight buffers per reactor is therefore the
current balanced starting point for up to 32 bursty clients; latency-critical
callers can provision toward their expected simultaneous receive fan-out.

The reusable io_uring backend owns persistent per-connection recvmsg and
sendmsg operation state while borrowing one reactor-wide provided-buffer group.
Send states point into contiguous reactor-owned descriptor and aligned ancillary
control slabs sized at initialization. Admission rejects a connection whose
logical transmit-FD budget exceeds one state's descriptor capacity, so preparing
a `sendmsg` never allocates and all kernel-visible iovec, control, and message
pointers remain stable until its CQE arrives. This per-slot operation metadata
does not reserve byte or descriptor backing; queued output still leases the
reactor-wide transmit pools. Send preparation can be batched before one shared
ring submission while each connection retains at most one active send SQE.
Receive decoding and buffer return are force-inlined across the module boundary;
the benchmark uses these exact library types rather than private equivalents.
After extraction, the isolated eight-connection median is about 93.2 million
messages/second.

The production reactor owner initializes the ring, provided-buffer group,
generation slots, fragment blocks, transmit blocks, and descriptor entries from
one caller allocator, with fallible initialization unwound in reverse order.
Actors receive logical budgets but lease physical capacity from those shared
pools. The owner is initialized in place and must retain a stable address while
live because Zig's provided-buffer group stores a pointer to its parent ring.
Both single- and multi-connection benchmark servers use this owner directly, so
their measured lifecycle and shared-pool layout match production code.

Consumers may instead lend an existing `IoUring` to the reactor. Owned and
borrowed initialization share the same resource setup and hot path; borrowed
teardown unregisters Wayring's provided-buffer group and frees its pools without
closing the ring. Both the external ring and reactor must remain at stable
addresses while registered operations can reference them.

Client object lookup uses fixed-capacity open addressing with a 75% maximum load
and backshift deletion, avoiding allocator traffic and long-lived tombstones on
the dispatch path. Server clients instead lease nodes from one reactor-wide
physical object pool, so idle clients do not reserve their entire logical object
quota. Each connection retains a small power-of-two bucket slab stamped with
its reactor generation. Reusing a slot therefore invalidates old bucket heads
without clearing the slab. Nodes also form an intrusive per-client ownership
chain, allowing disconnect teardown to return all objects to the shared free
list in O(1). Handles pair the wire ID with a pool-wide insertion generation so
an ID reused later cannot validate stale application state. Each namespace
caches its most recently resolved ID and node index; repeated dispatch to one
object avoids hashing and the bucket-chain walk, while removal always
walks the bucket chain to preserve collision unlinking. Allocation-free object
iterators expose generation-tagged handles and context-bearing object metadata
when applications need O(n) disconnect cleanup; callers that do not need hooks
retain the O(1) chain release path.
Server-created wire IDs are selected from the lowest free high-range value in
each client namespace rather than derived from shared physical node indices.
This keeps their externally visible sequence dense as required by libwayland,
while preserving reactor-wide object pooling and adding no per-client storage.

Logical per-client quotas prevent one connection from monopolizing the shared
pool. One physical node per inactive reactor slot is reserved for `wl_display`;
ordinary object creation cannot consume that reserve, so pool pressure cannot
prevent transport-capable clients from being admitted. Admission consumes its
reserved node, initializes the display namespace, and queues the first receive
transactionally. Teardown restores the reservation before recycling the slot.
Client-created IDs have a separate bounded lifecycle tracker: destructor
publication moves an ID into an awaiting-delete state, and only
`wl_display.delete_id` makes it reusable.
Creation failures that never reached the wire can be rolled back immediately.
Client object creation couples ID allocation and namespace insertion
transactionally; namespace backpressure returns the unpublished ID without
exposing a partial object. Server-created IDs occupy the protocol's high range
and use a separate insertion/removal path.
Core client operations are generic over a scanner-generated protocol module.
`sync`, `get_registry`, and dynamic registry binding create their target object
before direct encoding and roll it back if enqueue fails. Callback destructor
events retire the callback immediately, while the numeric ID remains held
until the display's later `delete_id` event.
Arbitrary generated client requests and events use the same metadata to apply
destructor lifecycle transactionally. A destructor request retires its object
only after the complete frame commits to TX; enqueue failure leaves it active.
A successfully decoded destructor event retires its object immediately, while
client-created numeric IDs remain unavailable until `wl_display.delete_id`.
Server-created high-range IDs are removed immediately because their reuse is
controlled by the server.
A client connection owner transactionally couples one reactor peer to its object
namespace and queues the initial receive only after `wl_display` exists. It owns
setup rollback and final teardown, but deliberately does not consume CQEs,
submit the ring, dispatch callbacks, or hide completion switches. Borrowed-ring
applications therefore retain batching policy and unrelated completion traffic.
An optional allocation-free client driver adds that repetitive completion
policy without changing ownership. It dispatches only CQEs prefiltered for its
connection, prepares coalesced sends and close cancellation, participates in
deferred receive rearming, and reports quiescence; the application still owns
submission and calls `Connection.deinit` with its allocator. External request
producers explicitly schedule the driver after queueing output. Typed optional
hooks report terminal event failures and final disconnection without dynamic
callback registration.
Against the same libwayland server, the client driver's five-sample throughput
median was 5.39 million messages/second versus 5.31 million for the handwritten
loop. A longer alternating latency run measured median p50 of 54.5 microseconds
for both paths and p99 of 85.0 versus 82.8 microseconds, preserving the manual
path's latency profile within orb scheduling noise.
The client also provides a composable asynchronous roundtrip adapter rather
than a blocking `wl_display_roundtrip` call. It owns one internal callback,
intercepts `callback.done` and the matching `display.delete_id`, forwards all
unrelated events and driver hooks, and performs no allocation beyond the
connection's existing bounded object table. Sending and waiting remain under
the caller's ring loop, so a roundtrip cannot hide a syscall or deadlock another
consumer sharing the ring.

Wayring does not copy libwayland's retained event-queue architecture into the
default path. Deferring raw events would require copying receive bytes, holding
or transferring descriptors, and partially applying constructor/destructor
object transitions before later events can be validated. Direct generated
dispatch instead exposes each object's context for immediate application-level
routing while preserving zero-copy selected-buffer processing. An optional
owned-event adapter may be added for cross-thread consumers, but its memory and
copying costs will remain explicit rather than taxing every connection.
Wayring operation tokens reserve low `user_data` bytes 1 through 5; borrowed-ring
consumers must use a disjoint tag namespace and pass only Wayring candidates to
reactor routing.
Core server operations use the same generated module and enforce the opposite
ID ownership boundary: client-created resources must use the low range, while
server-created objects come from a bounded high-range allocator. Display and
registry requests create resources only after typed decoding and version
validation. Sync completion preflights the combined `callback.done` and
`display.delete_id` frames before encoding either, then coalesces both behind a
single send SQE and removes the callback resource.
Generic server request decoding returns the generation-tagged target handle,
typed request value, and destructor bit while keeping the object live for the
application callback. After a successful callback, `finish` removes a
server-created object immediately or queues `wl_display.delete_id` before
removing a client-created object. TX backpressure leaves the latter object live,
so the runtime can close cleanly rather than exposing a partially completed ID
transition.
The server endpoint owns a configured listening descriptor and persistent
multishot accept state. It prepares accept and cancellation without submitting,
so both can share reactor-wide batches. Completion routing, accepted-client
admission, filesystem publication, and socket-path cleanup remain caller policy;
the endpoint closes its descriptor only after accept teardown has settled.
A server runtime transactionally composes that endpoint with the global table
and reactor-wide shared client/object storage. Routed accept completions admit a
client, capture its immutable Linux PID/UID/GID with one `SO_PEERCRED` query, and
queue its first receive without submission. Credentials share the generation-
checked client-slot allocation rather than requiring per-client allocation or
repeated syscalls. Active-peer iteration supports batched shutdown, while
connection CQE switches and protocol dispatch remain visible to the application.
Registry subscriptions lease entries from one configurable reactor-wide pool;
idle clients reserve none, and disconnect returns each client's chain in O(1).
Each subscription also owns its initial global-listing cursor. The runtime's
publication driver persists that cursor across TX backpressure, so applications
do not retain per-registry iteration state. Global-table mutation remains
serialized until all live initial listings finish, keeping their iterators valid
and ensuring older globals are queued before later changes. Disconnect releases
pending listings with the subscription chain in O(1).
Adding or removing a global snapshots the subscriptions that existed at that
point into one runtime-owned resumable publication cursor. A second mutation is
rejected until the first completes, preserving registry event order. Publication
queues at most one event per step, preserves its position under TX or shared-
block backpressure, and reports the affected peer for explicit send preparation.
Registries created while an update is pending use the current initial global
listing and are sequence-filtered from that update, preventing duplicate
announcements.
The optional server driver owns only allocation-free scheduling policy over a
borrowed runtime. It allocates one intrusive work node per reactor connection
slot at initialization, deduplicates peers needing send or close preparation,
dispatches batches of already-filtered Wayring CQEs, and prepares resulting
sends, cancellation, destruction, and deferred receives without submitting.
Application handlers receive the peer, resolved target, message, and descriptor
queue directly; optional connection, disconnection, and protocol-error hooks
remain statically dispatched. The driver advances the runtime's initial and
incremental global-publication cursors and schedules each affected peer, so
registry backpressure resumes on later send completions. External producers of
other events explicitly schedule the affected peer. Borrowed-ring users must
filter unrelated CQEs before dispatch and retain control of `submit`; if a
batch reports pending work because the SQ filled, they submit and call
`prepare` again. Thus the driver removes repetitive compositor event-loop code
without hiding ring ownership, batching, or another subsystem's completion
traffic.
An explicit shutdown request stops dispatch on every current peer, suppresses
further global publication, and batches listener plus socket cancellation
through the same pending-work machinery. Accept completions that race with
shutdown are admitted only long enough to acquire normal ownership and are then
closed without invoking the connected hook. Progress reports completion only
after the listener and all client slots are quiescent and destroyed; descriptor
and object cleanup therefore follows the ordinary generation-safe path.

Against the same libwayland client and generated protocol handler, the batched
driver's five-sample median was 7.80 million messages/second versus 7.11 million
for the handwritten one-CQE loop in this orb. Median round-trip p50 was 48.1
microseconds versus 46.1 microseconds and p99 was 97.5 versus 93.0 microseconds,
within the run's scheduling noise but worth retaining as a latency guardrail.
Generated codecs expose validated request and event sizes without allocating or
mutating TX state. Generic server event sending uses that preflight to reserve a
destructor event and its required `wl_display.delete_id` as one batch. It removes
the object only after both frames commit; server-created high IDs need only the
destructor event and are removed immediately after it commits.
Server global definitions live in one bounded reactor-wide table and are
referenced by every client registry. Names are monotonic and never reused;
binding checks the advertised interface and version before creating the
client-owned resource. Iteration exposes globals without copying or allocating,
so initial registry advertisement can be resumed under TX backpressure.
The framed dispatcher is generic over both namespace layouts, so client and
server runtimes retain direct compile-time-specialized lookup calls.

The framed dispatch loop is compile-time specialized for requests or events.
It advances the incremental framer, resolves object/interface/version metadata,
and calls the application's typed handler without reflection, function-pointer
registration, or allocation. Handlers explicitly return whether dispatch may
continue, so a terminal transition stops the current concatenated frame batch.
Internal object-table pointers are not retained across callbacks; handlers that
remove their source object can take a small metadata snapshot first.
Receive/dispatch helpers inline selected-buffer decoding, ancillary-FD ingestion,
framing, handler calls, and buffer return while deliberately leaving CQE routing
and receive rearming visible in the reactor loop. This avoids the generic
completion-pump abstraction that measured slower while centralizing buffer
ownership transitions. The server-side helper also converts malformed frames,
invalid object or method lookups, resource exhaustion, and unhandled callback
failures into the corresponding terminal `wl_display.error`; it reports the
cause to the caller while leaving send draining and receive cancellation
explicit. Selected `recvmsg` EOF is detected from the decoded payload length,
not the CQE result, because the latter includes io_uring's output metadata even
when the stream payload is empty. The eight-connection benchmark exercises the
shared server namespace directly. Its
80-million-message median is about 97.4 million messages/second, versus 90.2
million for the prior per-client table and about 3–5 million for libwayland in
the same orb.

## Compositor state

Reusable compositor policy is layered above generated protocol dispatch rather
than embedded in transport actors. The first protocol-independent primitive is
a fixed-size `wl_surface` state machine. It enforces permanent role identity and
live role-object destruction ordering, validates scale, transform, and
version-dependent attach offsets, and atomically commits buffer attachment,
surface and buffer damage, transform, scale, and content offset. Persistent
properties remain pending/current values while attachment, damage, and offset
are extracted and reset as one content update.

Damage uses one conservative bounding rectangle per coordinate space. This may
overdraw but cannot miss changed pixels, requires no region allocation, and
keeps the common surface commit path fixed-size. Exact opaque/input regions,
frame callback chains, synchronized subsurface content-update graphs, and
version-7 per-commit release callbacks remain separate composable state because
their storage and scheduling policy differ by compositor. The SHM
interoperability server exercises this state machine with real libwayland
attach, dual damage, transform, scale, offset, and commit requests.

## Initial transport candidate

- One ring per reactor thread, with connections permanently assigned to a ring.
- Multishot `recvmsg` with provided buffer rings.
- Ordinary `sendmsg`, with only one send in flight per connection.
- Multishot accept on the server side.
- No default `SQPOLL`, zero-copy send, or fixed-file registration until each is
  shown to improve the relevant benchmark profile.

The fixed-file experiment registers one slot-aligned socket table in each
benchmark process and marks persistent receive and send SQEs with
`IOSQE_FIXED_FILE`. A balanced six-sample, 32-connection run measured median
throughput of 85.1 million messages/second with ordinary descriptors and 84.1
million with fixed files. All-client tail latency was unchanged across 8 and 32
connections, while table registration cost roughly 3–8 microseconds per
process. Fixed files therefore remain an explicit caller-owned experiment; the
reactor does not acquire table-update syscalls or registered-file lifetime
complexity without evidence of a hot-path win.

An epoll plus `recvmsg`/`sendmsg` implementation will serve as the measurement
control rather than as a compatibility backend.

The listener keeps one generation-tagged multishot accept active and requests
`CLOEXEC|NONBLOCK` on every accepted descriptor. Accept and cancel completions
are separate state transitions, so shutdown does not release listener state
until both operations have terminated; stale completions from a rearmed
listener are rejected, and any descriptor carried by a stale successful accept
is closed immediately.

Filesystem Unix-socket setup is a separate policy-light layer. Client connect
returns only a fully connected close-on-exec, nonblocking descriptor ready for
reactor attachment. Server listen refuses to replace an existing path and does
not couple descriptor close to filesystem unlink; the compositor explicitly
owns stale-path detection and publication/removal policy. No socket helper
performs message-path allocation.
Relative display names can be resolved under a supplied runtime directory into
caller storage; absolute names and inherited descriptors remain supported
without consulting hidden process-global configuration.
The standard client bootstrap helper likewise takes an explicit Zig
environment value and caller storage. It honors inherited `WAYLAND_SOCKET`
before resolving `WAYLAND_DISPLAY` (defaulting to `wayland-0`) under
`XDG_RUNTIME_DIR`, and returns a configured nonblocking close-on-exec descriptor
without allocating.

Admission consumes an accepted descriptor and acquires the next free generation
slot in O(1), producing a compact generation-tagged peer handle. Sockets, actors,
and persistent receive states live in reactor-owned structure-of-arrays storage
indexed directly by that slot; CQE routing therefore needs no hash lookup or
consumer-maintained side table. If connection capacity is exhausted, admission
closes the descriptor instead of leaving ownership ambiguous. Peer destruction
is allowed only after receive and send teardown have completed, then recycles
the slot and closes the socket.

Admission can also queue the peer's initial multishot receive without submitting
the ring. A burst of accepted clients can therefore initialize their slot,
actor, and persistent receiver transactionally, then publish every receive SQE
with one shared `io_uring_enter`; failure recycles the slot and closes the socket.
Connected client descriptors use the same prepare-without-submit path, so many
outbound connections can join one initial receive submission as well.
An end-to-end core protocol test attaches both endpoints to one reactor and
drives `wl_display.sync`, `wl_callback.done`, and `wl_display.delete_id` through
the real multishot receive and persistent send completion paths.
The mixed interoperability harness repeats that lifecycle across the library
boundary in both directions: libwayland client to Wayring server and Wayring
client to libwayland server. It then measures generated custom-protocol
throughput, round-trip latency, syscalls, and hardware counters without linking
libwayland into the normal Wayring benchmark executable. Each pairing also
round-trips a real descriptor through generated protocol arguments and verifies
that the receiving side observes close-on-exec.
Peer shutdown is likewise completion-driven and batchable. One descriptor-wide
cancel SQE stops every active receive and send on that peer. Each actor remains
live until the cancel CQE and every terminating operation CQE arrive, preventing
slot reuse while the kernel can still reference persistent operation state or
queued TX storage. A reactor can queue cancellation for many peers before one
shared submission; the receive-only synchronous stop helper remains available
to lower-level users and allocates no temporary completion bitmap.

The benchmark includes a multi-connection mode in which one ring, one provided
buffer group, and shared fragment and transmit pools serve up to 64 socket
pairs. Client send SQEs are submitted once per cross-connection batch. This is
the relevant syscall-amortization benchmark; the single-connection mode remains
the direct per-message throughput comparison with raw sockets and libwayland.
The same harness records ping/pong round-trip latency distributions. A
multi-connection latency sample completes only when every connection's reply
has been dispatched, making tail and batching delay explicit.

## Implementation order

1. Wire framing and typed argument primitives.
2. Fragmentation and ancillary-FD transport harness.
3. io_uring receive, send, cancellation, and teardown state machines.
4. Protocol XML intermediate representation and direct codec generation.
5. Object namespace and core `wl_display`, `wl_registry`, and `wl_callback`.
6. Client runtime, followed by server globals, resources, and clients.
7. Comparative throughput, latency, allocation, RSS, and idle-CPU benchmarks.
