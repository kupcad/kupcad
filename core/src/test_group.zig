//! The groups the module's tests are split into, for build.zig and root.zig alike: the build
//! makes a test binary of each and runs them at once, and root.zig lists each group's files.
//! `zig build test` takes as long as the slowest group, so one that grows much longer than
//! the others is the one to split.

pub const TestGroup = enum { stdlib, vm, language, core, app };
