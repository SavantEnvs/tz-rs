# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for tz-rs (Rust / cargo-fuzz). Builds ON TOP of the org C/C++ base
# (ghcr.io/savantenvs/base), adding a pinned Rust nightly + cargo-fuzz under /opt/toolchains/rust,
# then runs mayhem/build.sh.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
# `--build-arg SANITIZER_FLAGS=` (empty) turns sanitizers OFF entirely (build.sh's off-switch).
ARG SANITIZER_FLAGS
# Debug-info contract knob (SPEC §6.2 item 10 — cargo-fuzz variant of DEBUG_FLAGS). Empty default
# so build.sh's own `-Cdebuginfo=2 -Zdwarf-version=3` fallback applies unless overridden.
ARG RUST_DEBUG_FLAGS=

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# nightly-2025-06-01: needed for -Zsanitizer=address (OSS-Fuzz Rust ASan path) and confirmed clean
# of the `log`-crate ICE that hits nightly-2025-01-15 under ASan (fleet field notes). Well past the
# 1.85 stabilization of edition 2024 that tz-rs's Cargo.toml requires.
ARG RUST_CHANNEL=nightly-2025-06-01
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
 # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# ── DWARF <= 3 anchor (SPEC §6.2 item 10) ───────────────────────────────────────
# Mayhem's triage reads the FIRST compile unit in .debug_info. rustc's own DWARF version knob
# (-Zdwarf-version=3 in RUSTFLAGS) covers rustc-compiled CUs, but NOT the prebuilt compiler-rt
# runtimes (ASan / libFuzzer) that get linked in unmodified, which may still ship DWARF>=4/5 CUs.
# So: force a hand-built, DWARF3, non-empty anchor CU to be the FIRST object the linker sees, via a
# thin linker wrapper passed as `-Clinker=...`. Verified: prepending (not appending) is required.
RUN printf 'int __mayhem_dwarf3_anchor;\n' > /opt/toolchains/rust/dwarf3-anchor.c \
 && clang -gdwarf-3 -c /opt/toolchains/rust/dwarf3-anchor.c -o /opt/toolchains/rust/dwarf3-anchor.o \
 && printf '#!/bin/sh\nexec clang "/opt/toolchains/rust/dwarf3-anchor.o" "$@"\n' > /opt/toolchains/rust/dwarf3-linker.sh \
 && chmod +x /opt/toolchains/rust/dwarf3-linker.sh \
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s) + the
# dynamically-linked KAT probe.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time IF present (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
