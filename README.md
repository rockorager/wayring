# wayring

An experimental Zig 0.16 Wayland implementation designed around Linux
`io_uring`.

Wayring targets Wayland wire compatibility, not libwayland API or architecture
compatibility. Its interfaces are unstable while the transport and ownership
model are established through measurement.

See [the architecture notes](docs/architecture.md) for the initial design.

`zig build test` runs the dependency-free unit and integration suite.
`zig build protocol-compat` additionally generates and compiles installed core
Wayland, xdg-shell, presentation-time, and linux-dmabuf protocols; it requires
the `wayland-protocols` package.
