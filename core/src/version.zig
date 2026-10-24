//! What kupcad says of itself to a front end choosing it: its version, the protocol version
//! it speaks (preview/frame.zig) and the platform it was built for. `kupcad version --json`
//! prints it, and the browser's `version_wasm` returns it.

const builtin = @import("builtin");
const build_info = @import("build_info");
const frame = @import("preview/frame.zig");

/// `{"version": "0.1.0", "protocolVersion": 1, "os": "macos", "arch": "aarch64"}`.
pub const Info = struct {
    version: []const u8 = build_info.version,
    protocolVersion: u32 = frame.PROTOCOL_VERSION,
    os: []const u8 = @tagName(builtin.os.tag),
    arch: []const u8 = @tagName(builtin.cpu.arch),
};
