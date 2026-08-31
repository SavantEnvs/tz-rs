//! mayhem/kat — a small, DYNAMICALLY LINKED known-answer-test probe over tz-rs's public API
//! (the localtime/gmtime/mktime-equivalent surface: TimeZone lookups, TZif parsing, POSIX TZ
//! string parsing, and calendar <-> Unix-time conversion). This is the behavioral oracle that
//! mayhem/test.sh asserts against — NOT `cargo test` alone (that links a test binary that, under
//! this fleet's sabotage shim, survives being neutered and would prove nothing; see the fleet's
//! netnew-worker-prompt.md §4).
//!
//! Every assertion below is a FIXED input -> an EXACT expected value, several lifted directly
//! from tz-rs's own published doctest in src/lib.rs so they are provably the crate authors'
//! intended behavior, not something we invented. A neutered/no-op build of tz-rs makes at least
//! one of these mismatch (or panic on the initial parse), so this probe fails loudly under the
//! anti-reward-hacking sabotage check.
//!
//! Must build DYNAMICALLY LINKED (Rust's default on this target) so the fleet's LD_PRELOAD-based
//! sabotage shim can intercept it; build.sh asserts this with `file | grep 'dynamically linked'`.

use std::process::ExitCode;

use tz::{DateTime, TimeZone, UtcDateTime};

/// mayhem/parse_file's own seed: a real, unmodified `America/New_York` TZif v2 file (IANA
/// tzdata), committed at mayhem/parse_file/testsuite/tz_new_york.tzif and reused here as the
/// probe's fixed input to `TimeZone::from_tz_data` (the TZif/gmtime-equivalent parse path).
static NEW_YORK_TZIF: &[u8] = include_bytes!("../../parse_file/testsuite/tz_new_york.tzif");

/// A hand-built RFC 8536 TZif v1 file exercising the leap-second table (mirrors tz-rs's own
/// `test_v1_file_with_leap_seconds` unit test fixture in src/parse/tz_file.rs), committed at
/// mayhem/parse_file/testsuite/tz_v1_leap_seconds.tzif.
static V1_LEAP_SECONDS_TZIF: &[u8] = include_bytes!("../../parse_file/testsuite/tz_v1_leap_seconds.tzif");

struct Checks {
    passed: u32,
    failed: u32,
}

impl Checks {
    fn new() -> Self {
        Self { passed: 0, failed: 0 }
    }

    fn check<T: PartialEq + std::fmt::Debug>(&mut self, name: &str, got: T, want: T) {
        if got == want {
            self.passed += 1;
            println!("ok   {name}: {got:?}");
        } else {
            self.failed += 1;
            eprintln!("FAIL {name}: got {got:?}, want {want:?}");
        }
    }

    fn error(&mut self, name: &str, msg: impl std::fmt::Display) {
        self.failed += 1;
        eprintln!("FAIL {name}: unexpected error: {msg}");
    }
}

fn main() -> ExitCode {
    let mut c = Checks::new();

    // ---- UtcDateTime <-> Unix time (the gmtime/timegm-equivalent path) ------------------------
    // 2000-01-01T00:00:00.123456789Z, per tz-rs's own README/lib.rs doctest.
    match UtcDateTime::new(2000, 1, 1, 0, 0, 0, 123_456_789) {
        Ok(dt) => {
            c.check("UtcDateTime.year", dt.year(), 2000);
            c.check("UtcDateTime.month", dt.month(), 1);
            c.check("UtcDateTime.month_day", dt.month_day(), 1);
            c.check("UtcDateTime.hour", dt.hour(), 0);
            c.check("UtcDateTime.minute", dt.minute(), 0);
            c.check("UtcDateTime.second", dt.second(), 0);
            c.check("UtcDateTime.week_day", dt.week_day(), 6);
            c.check("UtcDateTime.year_day", dt.year_day(), 0);
            c.check("UtcDateTime.unix_time", dt.unix_time(), 946_684_800_i64);
            c.check("UtcDateTime.nanoseconds", dt.nanoseconds(), 123_456_789);
        }
        Err(e) => c.error("UtcDateTime::new", e),
    }

    // ---- TimeZone::utc() / TimeZone::fixed() (localtime-equivalent lookup) --------------------
    let unix_time = 946_684_800_i64; // 2000-01-01T00:00:00Z
    match TimeZone::utc().find_local_time_type(unix_time) {
        Ok(t) => c.check("TimeZone::utc().ut_offset", t.ut_offset(), 0),
        Err(e) => c.error("TimeZone::utc() lookup", e),
    }
    match TimeZone::fixed(-3600) {
        Ok(tz) => match tz.find_local_time_type(unix_time) {
            Ok(t) => c.check("TimeZone::fixed(-3600).ut_offset", t.ut_offset(), -3600),
            Err(e) => c.error("TimeZone::fixed(-3600) lookup", e),
        },
        Err(e) => c.error("TimeZone::fixed(-3600)", e),
    }

    // ---- POSIX TZ string parsing (the TZ-environment-variable path) ---------------------------
    // "HST10" = Hawaii Standard Time, 10 hours WEST of UTC -> UTC offset -36000s (POSIX sign
    // convention: a positive field value means west of UTC).
    match TimeZone::from_posix_tz("HST10") {
        Ok(tz) => match tz.find_local_time_type(0) {
            Ok(t) => c.check("from_posix_tz(HST10).ut_offset", t.ut_offset(), -36_000),
            Err(e) => c.error("from_posix_tz(HST10) lookup", e),
        },
        Err(e) => c.error("from_posix_tz(HST10)", e),
    }
    // Per tz-rs's own doctest: these TZ strings are invalid (a DST rule with a zero-length DST
    // period, and an empty string).
    c.check("from_posix_tz(EST5EDT,0/0,J365/25).is_err", TimeZone::from_posix_tz("EST5EDT,0/0,J365/25").is_err(), true);
    c.check("from_posix_tz(empty).is_err", TimeZone::from_posix_tz("").is_err(), true);

    // ---- TZif (RFC 8536) file parsing over a REAL, unmodified IANA tzdata file -----------------
    // America/New_York on 2000-01-01T00:00:00Z is EST (UTC-5), independently verified against
    // Python's zoneinfo: `datetime(2000,1,1,tzinfo=utc).astimezone(ZoneInfo("America/New_York"))`
    // -> 1999-12-31 19:00:00-05:00.
    match TimeZone::from_tz_data(NEW_YORK_TZIF) {
        Ok(tz) => match tz.find_local_time_type(unix_time) {
            Ok(t) => c.check("America/New_York@2000-01-01T00:00:00Z.ut_offset", t.ut_offset(), -18_000),
            Err(e) => c.error("America/New_York lookup", e),
        },
        Err(e) => c.error("America/New_York TZif parse", e),
    }

    // ---- TZif v1 with a leap-second table (exercises the leap-second data block) ---------------
    match TimeZone::from_tz_data(V1_LEAP_SECONDS_TZIF) {
        Ok(tz) => c.check("v1_leap_seconds.leap_second_count", tz.as_ref().leap_seconds().len(), 27),
        Err(e) => c.error("v1-with-leap-seconds TZif parse", e),
    }

    // ---- DateTime::find (the mktime-equivalent path: calendar time + zone -> Unix time) --------
    // A fixed offset zone at UTC-1: 2000-01-01T00:00:00 local time in UTC-1 is 2000-01-01T01:00:00Z.
    match TimeZone::fixed(-3600) {
        Ok(tz) => match DateTime::find(2000, 1, 1, 0, 0, 0, 0, tz.as_ref()) {
            Ok(found) => match found.unique() {
                Some(dt) => c.check("DateTime::find(UTC-1).unix_time", dt.unix_time(), 946_688_400_i64),
                None => {
                    c.failed += 1;
                    eprintln!("FAIL DateTime::find(UTC-1) did not return a unique result");
                }
            },
            Err(e) => c.error("DateTime::find(UTC-1)", e),
        },
        Err(e) => c.error("TimeZone::fixed(-3600) [mktime case]", e),
    }

    println!("kat_probe: {} passed, {} failed", c.passed, c.failed);
    if c.failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
