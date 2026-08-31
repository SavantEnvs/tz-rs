// mayhem/lsan_off.c
//
// Fleet policy: disable LeakSanitizer at build/link time for every ASan-built target,
// proactively. ASan's own memory-corruption checks and UBSan stay fully active; only leak
// detection is affected. Injected via a linker arg from mayhem/build.sh (RUSTFLAGS
// -C link-arg=<object>) rather than editing the fuzz target sources directly, to keep this
// additive-only (fuzz/fuzz_targets/*.rs are upstream's own pre-existing files).
int __lsan_is_turned_off(void) {
    return 1;
}
