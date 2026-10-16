//! Bindings to Draco's C functions: `encodeMesh` compresses positions and triangle indices
//! into a Draco buffer, copied into Zig memory, for the glTF exporter
//! (`exporters/3d/gltf.zig`); `decodeMesh` reads one back, for the tests that check exports.

const std = @import("std");

// ==========================================
// C Extern Declarations
// ==========================================

pub const DracoEncodedBuffer = extern struct {
    data: ?[*]const u8,
    size: usize,
};

extern fn draco_encode_mesh(
    positions: [*]const f32,
    num_vertices: usize,
    indices: [*]const u32,
    num_indices: usize,
    pos_quantization_bits: c_int,
) DracoEncodedBuffer;

extern fn draco_free_buffer(buf: DracoEncodedBuffer) void;

const DracoDecodedMesh = extern struct {
    positions: ?[*]f32,
    num_vertices: usize,
    indices: ?[*]u32,
    num_indices: usize,
};

extern fn draco_decode_mesh(data: [*]const u8, size: usize, out: *DracoDecodedMesh) c_int;
extern fn draco_free_decoded_mesh(mesh: *DracoDecodedMesh) void;

pub const DracoError = error{
    InvalidPositionsLength,
    InvalidIndicesLength,
    EncodingFailed,
    OutOfMemory,
};

// ==========================================
// Zig Idiomatic Wrappers
// ==========================================

/// Encodes raw positions and triangle indices into a Draco compressed buffer.
/// Returns a Zig-allocated owned slice (`[]u8`) that the caller manages.
pub fn encodeMesh(
    allocator: std.mem.Allocator,
    positions: []const f32, // Must be VEC3 (stride of 3 floats per vertex)
    indices: []const u32, // Triangle indices (stride of 3 u32s per face)
    pos_quantization_bits: i32, // Standard is 14 bits for high precision CAD, 0 for lossless
) DracoError![]u8 {
    if (positions.len % 3 != 0) return error.InvalidPositionsLength;
    if (indices.len % 3 != 0) return error.InvalidIndicesLength;

    const num_vertices = positions.len / 3;
    const num_indices = indices.len;

    const c_buf = draco_encode_mesh(
        positions.ptr,
        num_vertices,
        indices.ptr,
        num_indices,
        @intCast(pos_quantization_bits),
    );

    if (c_buf.data == null or c_buf.size == 0) {
        return error.EncodingFailed;
    }
    defer draco_free_buffer(c_buf);

    // Copy to a Zig-managed slice so memory allocation remains consistent with the rest of the engine
    const result = allocator.alloc(u8, c_buf.size) catch return error.OutOfMemory;
    @memcpy(result, c_buf.data.?[0..c_buf.size]);

    return result;
}

/// A mesh read back from a Draco buffer, in Zig memory.
pub const DecodedMesh = struct {
    /// Three per vertex.
    positions: []f32,
    /// Three per triangle.
    indices: []u32,

    pub fn deinit(self: DecodedMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.indices);
    }
};

/// Decodes a Draco mesh buffer (what `encodeMesh` writes) into positions and indices.
pub fn decodeMesh(allocator: std.mem.Allocator, bytes: []const u8) (error{DecodingFailed} || std.mem.Allocator.Error)!DecodedMesh {
    var c_mesh: DracoDecodedMesh = undefined;
    if (draco_decode_mesh(bytes.ptr, bytes.len, &c_mesh) != 0) return error.DecodingFailed;
    defer draco_free_decoded_mesh(&c_mesh);
    const positions = try allocator.dupe(f32, if (c_mesh.positions) |p| p[0 .. c_mesh.num_vertices * 3] else &.{});
    errdefer allocator.free(positions);
    return .{ .positions = positions, .indices = try allocator.dupe(u32, if (c_mesh.indices) |i| i[0..c_mesh.num_indices] else &.{}) };
}
