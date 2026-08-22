# wayring

An experimental Zig 0.16 Wayland implementation designed around Linux
`io_uring`.

Wayring targets Wayland wire compatibility, not libwayland API or architecture
compatibility. Its interfaces are unstable while the transport and ownership
model are established through measurement.

Wayring stops at client/server runtime mechanics: wire and generated protocol
dispatch, io_uring transport, objects and resources, globals, descriptors,
socket setup, and safe SHM access. Surface, renderer, input, and shell semantics
belong to Ouro, the compositor built on Wayring.

See [the architecture notes](docs/architecture.md) for the initial design.

## Requirements

- Linux with io_uring support
- Zig 0.16

Wayring itself has no libwayland dependency. Optional compatibility checks and
benchmarks use upstream Wayland XML and system libwayland in an isolated build
package; normal consumers fetch and link neither.

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
- `wayring.server`: globals, resources, generated dispatch, and server drivers
- `wayring.objects`: bounded generation-checked object namespaces
- `wayring.shm`: validated SHM metadata, mapping lifetime, and safe import paths
- `wayring.unix_socket`: Wayland display socket setup and connection helpers

Initialization APIs take an allocator and pair it with an explicit `deinit`.
Steady-state receive, dispatch, and transmit paths use bounded shared pools and
do not allocate per message.

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
