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

/// Zero-copy wrapper variant: returns a struct wrapping the raw C allocation.
/// Must call `deinit()` when finished to free the C buffer directly.
pub const EncodedMeshBuffer = struct {
    bytes: []const u8,
    raw_buf: DracoEncodedBuffer,

    pub fn deinit(self: EncodedMeshBuffer) void {
        draco_free_buffer(self.raw_buf);
    }
};

pub fn encodeMeshZeroCopy(
    positions: []const f32,
    indices: []const u32,
    pos_quantization_bits: i32,
) DracoError!EncodedMeshBuffer {
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

    return .{
        .bytes = c_buf.data.?[0..c_buf.size],
        .raw_buf = c_buf,
    };
}
