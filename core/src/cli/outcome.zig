//! How a CLI command finished. Commands return an Outcome instead of calling
//! std.process.exit themselves, so main maps every command to an exit status the same way.

/// Exit status for any failed command, so scripts and CI can detect errors.
pub const EXIT_FAILURE: u8 = 1;

pub const Outcome = enum { success, failure };
