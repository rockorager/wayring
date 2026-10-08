# wayring

An experimental Zig 0.16 Wayland implementation designed around Linux
`io_uring`.

Wayring targets Wayland wire compatibility, not libwayland API or architecture
compatibility. Its interfaces are unstable while the transport and ownership
model are established through measurement.

Wayring stops at client/server runtime mechanics: wire and generated protocol
dispatch, io_uring transport, objects and resources, globals, descriptors,
socket setup, and safe SHM access. Consumers own application scheduling,
protocol-specific object semantics, rendering, input, and shell policy.

See [the architecture notes](docs/architecture.md) for the initial design.

## Requirements

- Linux with io_uring support
- Zig 0.16

Wayring itself has no libwayland dependency. Optional compatibility checks and
benchmarks use upstream Wayland XML and system libwayland in an isolated build
package; normal consumers fetch and link neither.

Set `WAYLAND_DEBUG=1` to trace generated client and server protocol traffic to
standard error. `WAYLAND_DEBUG=client` and `WAYLAND_DEBUG=server` select one
side. Tracing remains available in release builds; when disabled, each message
pays only one atomic load and a predictable branch.

## Use as a Zig dependency

Add a published Wayring package to your manifest:

```sh
zig fetch --save <wayring-package-url>
```

Then expose the module to your application:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dependency = b.dependency("wayring", .{
    .target = target,
    .optimize = optimize,
});

const application = b.addExecutable(.{
    .name = "compositor",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "wayring",
            .module = dependency.module("wayring"),
        }},
    }),
});
b.installArtifact(application);
```

The primary entry points are:

- `wayring.io_uring.Reactor`: owned or borrowed-ring transport reactor
- `wayring.client`: generated request/event dispatch and client drivers
- `wayring.server`: globals, resources, generated dispatch, server drivers, and
  the optional `wl_shm` protocol service
- `wayring.objects`: generation-checked object namespaces with logical quotas
- `wayring.shm`: validated SHM metadata, mapping lifetime, and safe import paths
- `wayring.unix_socket`: Wayland display socket setup and connection helpers

Initialization APIs take an allocator and pair it with an explicit `deinit`.
Shared fragment, transmit, descriptor, and server-object pools start with
configured reserves and grow on demand, including on the message path.
Per-connection logical budgets still provide backpressure. Returned pool
capacity is retained for reuse until teardown.
`deinit` releases all grown capacity and closes runtime-owned descriptors.

### Safe global removal

`server.Runtime.removeGlobal` unpublishes a global, but retains its definition
and binder while registry offers remain outstanding. Racing binds from those
clients still invoke the original binder, which must create a valid (possibly
inert) resource. Keep the global context alive until the callback passed to
`removeGlobalWithCallback(handle, callback)` runs. The callback receives the
global context and handle, may run synchronously, and must not reenter the
runtime. Already-bound resources have independent lifetimes.

A `wl_fixes` v2 adapter should decode requests with `server.decodeRequest`,
resolve the registry argument in the requesting client's namespace, and call
`runtime.ackGlobalRemove(peer, registry_handle, name)`. Map `InvalidAckRemove`
to `wl_fixes.invalid_ack_remove` on the fixes object using `Core.postError`.
Unknown, duplicate, unannounced, and not-yet-published removals are invalid.
Destroy registries through `runtime.removeRegistry` and clients through
`runtime.destroyClient`; both release their outstanding offers automatically.

Each registry must acknowledge separately, even if it never bound the global.
A registry that had not yet been sent the global when it was removed is never
told about it and holds no offer.
Clients without v2 support retain offers until registry destruction or
disconnect: there is no unsafe timeout. Retired definitions do not consume
`max_globals`, but can accumulate while old or non-acknowledging clients remain.
Global names are never reused, even after collection; exhaustion returns
`NameExhausted`. Use runtime publication/removal APIs once clients exist, not
direct `Globals` mutations or manually encoded registry events.

## Generate protocol bindings

The scanner accepts one or more XML files followed by the generated Zig output:

```sh
zig build
zig-out/bin/wayring-scanner wayland.xml viewporter.xml protocol.zig
```

Generated modules import `wayring`, so add the Wayring module to their build
imports. Passing dependency XML before the protocol that references it lets the
scanner resolve cross-protocol interfaces.

Generate browsable API documentation with `zig build docs`; output is written
to `zig-out/docs`.

## Validation

`zig build test` runs the dependency-free unit and integration suite.
`zig build protocol-compat` additionally generates and compiles pinned upstream
core Wayland and stable production protocols, then checks scanner compatibility
across the complete stable, staging, unstable, and experimental XML corpus.

`zig build fuzz` runs each fuzz target once as a deterministic seed check.
Use `zig build fuzz --fuzz=1M` for one million coverage-guided iterations per
target, or omit the limit for continuous fuzzing with Zig's web interface.

`zig build soak` exercises randomized multi-connection traffic, descriptor
transfer, forced shared RX/TX pressure, cancellation, and slot reuse against
the real kernel io_uring path.
Use `-Dsoak-rounds=N` and `-Dsoak-seed=N` to extend or reproduce a run.
