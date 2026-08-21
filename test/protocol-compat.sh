#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scanner=$1
wayland_source=$2
protocols_source=$3
temporary=$(mktemp -d)
generated="$temporary/standard.zig"
trap 'rm -rf "$temporary"' EXIT

"$scanner" \
    "$wayland_source/protocol/wayland.xml" \
    "$protocols_source/stable/xdg-shell/xdg-shell.xml" \
    "$protocols_source/stable/presentation-time/presentation-time.xml" \
    "$protocols_source/stable/linux-dmabuf/linux-dmabuf-v1.xml" \
    "$generated"
zig fmt "$generated" >/dev/null
zig test -OReleaseSafe \
    --dep wayring --dep standard_protocols \
    -Mroot="$root/test/standard-protocols.zig" \
    --dep wayring -Mstandard_protocols="$generated" \
    -Mwayring="$root/src/root.zig"

corpus_list="$temporary/corpus.list"
find "$protocols_source/stable" \
    "$protocols_source/staging" \
    "$protocols_source/unstable" \
    "$protocols_source/experimental" \
    -type f -name '*.xml' | sort > "$corpus_list"

while IFS= read -r protocol; do
    "$scanner" "$wayland_source/protocol/wayland.xml" \
        "$protocol" "$temporary/corpus.zig"
    zig fmt "$temporary/corpus.zig" >/dev/null
done < "$corpus_list"

compile_corpus() {
    list=$1
    set -- "$wayland_source/protocol/wayland.xml"
    while IFS= read -r protocol; do
        set -- "$@" "$protocol"
    done < "$list"
    "$scanner" "$@" "$temporary/corpus.zig"
    zig fmt "$temporary/corpus.zig" >/dev/null
    zig test -OReleaseSafe \
        --dep wayring --dep corpus_protocol \
        -Mroot="$root/test/protocol-corpus-codecs.zig" \
        --dep wayring -Mcorpus_protocol="$temporary/corpus.zig" \
        -Mwayring="$root/src/root.zig"
}

primary_list="$temporary/primary.list"
find "$protocols_source/stable" \
    "$protocols_source/staging" \
    "$protocols_source/experimental" \
    -type f -name '*.xml' | sort > "$primary_list"
compile_corpus "$primary_list"

unstable_list="$temporary/unstable.list"
find "$protocols_source/unstable" \
    -type f -name '*.xml' | sort > "$unstable_list"
compile_corpus "$unstable_list"
