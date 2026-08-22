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
