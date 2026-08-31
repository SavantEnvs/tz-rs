#!/usr/bin/env bash
#
# mayhem/build.sh — build tz-rs's cargo-fuzz targets as sanitized libFuzzer binaries, PLUS a clean
# (non-sanitized) oracle build: the dynamically-linked KAT probe (mayhem/kat) and the project's own
# `cargo test` binary. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the crates.io index over
#     the (absent) network — so we never hard-code `--offline` here (it would break this first,
#     online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"
DWARF3_LINKER="/opt/toolchains/rust/dwarf3-linker.sh"

# Debug-info contract knob (SPEC §6.2 item 10, cargo-fuzz variant): DWARF < 4 so Mayhem's triage
# (and ASan/gdb) can resolve project source lines. -Cdebuginfo=2 keeps full symbols;
# -Zdwarf-version=3 pins rustc-compiled CUs to DWARF3 (clang-19/LLVM19 default DWARF5 otherwise).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3}"

# Sanitizer off-switch parity with the C/C++ contract: the base sets $SANITIZER_FLAGS (ASan+UBSan)
# as the default; `--build-arg SANITIZER_FLAGS=` (empty) disables sanitizers entirely so the target
# gets a natural, unsanitized crash instead. rustc has no UBSan-equivalent -Zsanitizer mode, so a
# non-empty $SANITIZER_FLAGS maps to the OSS-Fuzz Rust ASan path (-Zsanitizer=address); empty maps
# to no sanitizer at all.
SAN_RUSTFLAGS=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  SAN_RUSTFLAGS="-Zsanitizer=address"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────
# 1) Sanitized libFuzzer targets (upstream's OWN fuzz/ crate — it already builds on the pinned
#    nightly, so we use it as-is rather than adding an additive mayhem/fuzz/ crate).
# ─────────────────────────────────────────────────────────────────────────────────────────────
FUZZ_DIR="fuzz"

# OSS-Fuzz Rust libFuzzer(+ASan) flags. cargo-fuzz sets the ASan flag itself when instrumenting,
# but we pin it explicitly via $SAN_RUSTFLAGS above so the off-switch works. --cfg fuzzing matches
# libfuzzer-sys; force-frame-pointers aids ASan backtraces. $RUST_DEBUG_FLAGS's -Zdwarf-version=3
# covers rustc-compiled CUs; it does NOT cover the prebuilt ASan/libFuzzer compiler-rt runtimes
# linked in unmodified, so we ALSO prepend a hand-built DWARF3 anchor CU via a linker wrapper
# (-Clinker=$DWARF3_LINKER) so Mayhem's triage — which reads only the FIRST CU in .debug_info —
# sees DWARF3 regardless of what those runtimes ship.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${SAN_RUSTFLAGS} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers -Clinker=${DWARF3_LINKER}"

# Skip libfuzzer-sys's own bundled-C++ libFuzzer compile (its build.rs would otherwise invoke its
# own clang++ build of libFuzzer, which can ship DWARF5 debug info untouched by the RUSTFLAGS
# above) and link the base image's own prebuilt libclang_rt.fuzzer instead.
export CUSTOM_LIBFUZZER_PATH="/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a"
[ -f "$CUSTOM_LIBFUZZER_PATH" ] || { echo "ERROR: expected prebuilt libFuzzer archive not found at $CUSTOM_LIBFUZZER_PATH" >&2; exit 1; }

# Fleet policy: disable LeakSanitizer for both fuzz binaries (ASan's own memory-corruption checks
# and UBSan stay active — only leak detection is affected). LSan looks up the C-ABI symbol
# `__lsan_is_turned_off` at process exit; we provide it via a tiny standalone object
# (mayhem/lsan_off.c) linked in through RUSTFLAGS, rather than editing the fuzz target sources
# directly — fuzz/fuzz_targets/*.rs are upstream's own pre-existing files and must stay untouched
# for the additive-only replay gate. `-Wl,--undefined=...` forces the linker to keep the symbol
# even if it would otherwise be GC'd as unreferenced (e.g. under --gc-sections).
LSAN_OFF_OBJ="/tmp/lsan_off.o"
clang -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"
[ -f "$LSAN_OFF_OBJ" ] || { echo "ERROR: failed to build $LSAN_OFF_OBJ from mayhem/lsan_off.c" >&2; exit 1; }
export RUSTFLAGS="${RUSTFLAGS} -C link-arg=${LSAN_OFF_OBJ} -C link-arg=-Wl,--undefined=__lsan_is_turned_off"

FUZZ_TARGETS=(parse_file parse_string)

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "SANITIZER_FLAGS=${SANITIZER_FLAGS:-<empty — sanitizers OFF>}"
echo "RUST_DEBUG_FLAGS=$RUST_DEBUG_FLAGS"
echo "RUSTFLAGS=$RUSTFLAGS"
echo "CUSTOM_LIBFUZZER_PATH=$CUSTOM_LIBFUZZER_PATH"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # fuzz/Cargo.toml declares its OWN [workspace] (upstream's root Cargo.toml has none), so the fuzz
  # crate is its own workspace root and cargo-fuzz writes under fuzz/target/, not the repo root's.
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ─────────────────────────────────────────────────────────────────────────────────────────────
# 2) Clean (non-sanitized) oracle build: the KAT probe. Separate target dir + no ASan/DWARF3
#    overrides, so it coexists with the sanitized build above with no clean/stash dance, and stays
#    an HONEST oracle (the project's normal flags, dynamically linked so the sabotage shim can
#    intercept it).
# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "=== building mayhem/kat (clean, dynamically-linked KAT probe) ==="
env -u RUSTFLAGS -u CUSTOM_LIBFUZZER_PATH \
  cargo build --release --manifest-path mayhem/kat/Cargo.toml --target-dir mayhem/kat/target

kat_bin="$SRC/mayhem/kat/target/release/kat_probe"
[ -x "$kat_bin" ] || { echo "ERROR: expected KAT probe binary not found at $kat_bin" >&2; exit 1; }
cp "$kat_bin" /mayhem/kat_probe

# Regression guard (fleet field notes): Rust binaries are dynamically linked by default on this
# target — assert it stays that way, since the sabotage shim can only intercept a dynamically
# linked executable.
file /mayhem/kat_probe
file /mayhem/kat_probe | grep -q 'dynamically linked' \
  || { echo "ERROR: /mayhem/kat_probe is not dynamically linked — the behavioral oracle would be unsandbaggable" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────────────────────
# 3) Precompile the project's own `cargo test` suite (clean build; test.sh only RUNS it).
# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "=== precompiling cargo test (clean, informational — NOT the primary oracle) ==="
env -u RUSTFLAGS -u CUSTOM_LIBFUZZER_PATH \
  cargo test --no-run --target-dir mayhem/test-target

echo "build.sh complete"
