//! What kupcad says of itself to a front end choosing it: its version, the protocol version
//! it speaks (preview/frame.zig), the platform it was built for and the formats it exports.
//! `kupcad version --json` prints it, the browser's `version_wasm` and libkupcad's
//! `kupcad_version` return it.

const builtin = @import("builtin");
const build_info = @import("build_info");
const frame = @import("preview/frame.zig");
const ExportFormat = @import("exporters/format.zig").ExportFormat;

/// `{"version": "0.1.0", "protocolVersion": 1, "os": "macos", "arch": "aarch64",
/// "formats": ["stl", "glb", ...]}`.
pub const Info = struct {
    version: []const u8 = build_info.version,
    protocolVersion: u32 = frame.PROTOCOL_VERSION,
    os: []const u8 = @tagName(builtin.os.tag),
    arch: []const u8 = @tagName(builtin.cpu.arch),
    /// The formats a model builds in, by the names `kupcad build -f` takes
    formats: []const [:0]const u8 = @typeInfo(ExportFormat).@"enum".field_names,
};
