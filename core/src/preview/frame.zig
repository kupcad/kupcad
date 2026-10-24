//! The preview frame: what a front end is given to show a run of a script, from the language
//! server's viewport socket and from the browser's `preview_wasm` alike. A frame is the
//! length of its header (u32, little-endian), the header (JSON: `Header`), then the body:
//! the model as GLB for a `3d` frame, as SVG for a `2d` one, nothing for `none`.
//!
//! `PROTOCOL_VERSION` numbers what passes between the core and a front end: this frame,
//! `kupcad/viewportReady` and the `kupcad.setParams` command. It goes up when one of them
//! changes shape, and a front end refuses a version it doesn't know rather than misread it.
//! `kupcad version --json` gives it, for a front end choosing a binary.

const std = @import("std");
const UiSchema = @import("../tools/doc/extractor.zig").UiSchema;
const ParamValues = @import("../core/param_values.zig").ParamValues;

pub const PROTOCOL_VERSION: u32 = 1;
/// The header's length, before it.
const LENGTH_BYTES = 4;

/// What the body holds.
pub const Kind = enum {
    /// GLB: the model's Solids, each copy a node named after its part, and its ghosts.
    @"3d",
    /// SVG: the model's Sketches and Paths, each shape a path with its name as its id.
    @"2d",
    /// Nothing: the run left no model, or failed (`Header.error` says why).
    none,
};

/// The JSON header. Its field names are the protocol's.
pub const Header = struct {
    protocolVersion: u32 = PROTOCOL_VERSION,
    kind: Kind,
    /// A `3d` frame's parts, as the parts list groups its Solids.
    parts: []const Part = &.{},
    warnings: []const Warning = &.{},
    params: Params,
    /// Why the run failed (`kind` is then `none`), or null.
    @"error": ?Failure = null,
    timing: Timing,
};

pub const Part = struct {
    name: []const u8,
    count: u32,
    /// The GLB's nodes of its copies, in their order: "lid", "lid_2".
    nodes: []const []const u8,
    /// "#rrggbb", or null for a part without a colour of its own.
    color: ?[]const u8,
    opacity: f64,
};

/// A warning of the run, at the line and column (1-based, the column in UTF-8 bytes) the
/// script was at; null where it wasn't running (a warning while the model was meshed).
pub const Warning = struct {
    message: []const u8,
    line: ?u32,
    column: ?u32,
};

pub const Params = struct {
    /// What `kupcad doc` gives: the meta and each parameter's declaration.
    schema: UiSchema,
    /// The value each parameter took in the run, in the order it asked for them.
    values: ParamValues,
};

/// Why the run failed: its message, where (as Warning's), and the parameter whose value it
/// refused, for a front end's control to show.
pub const Failure = struct {
    message: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    param: ?[]const u8 = null,
};

/// Milliseconds spent running the script and making the body.
pub const Timing = struct {
    runMs: f64,
    renderMs: f64,
};

/// The frame of `header` and `body`, owned by `allocator`.
pub fn encode(allocator: std.mem.Allocator, header: Header, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.splatByteAll(0, LENGTH_BYTES);
    try std.json.Stringify.value(header, .{}, &out.writer);
    const header_len = std.math.cast(u32, out.written().len - LENGTH_BYTES) orelse return error.FrameTooLarge;
    std.mem.writeInt(u32, out.written()[0..LENGTH_BYTES], header_len, .little);
    try out.writer.writeAll(body);
    return out.toOwnedSlice();
}

/// A frame's header (JSON text) and body, borrowed from `bytes`.
pub const Parts = struct { header: []const u8, body: []const u8 };

/// `bytes` as a frame's header and body; error.BadFrame when its length doesn't fit.
pub fn split(bytes: []const u8) error{BadFrame}!Parts {
    if (bytes.len < LENGTH_BYTES) return error.BadFrame;
    const header_len = std.mem.readInt(u32, bytes[0..LENGTH_BYTES], .little);
    if (header_len > bytes.len - LENGTH_BYTES) return error.BadFrame;
    return .{ .header = bytes[LENGTH_BYTES..][0..header_len], .body = bytes[LENGTH_BYTES + header_len ..] };
}
