const std = @import("std");

// --- Strictly Typed B-Rep Graph Indices ---
pub const VertexIndex = enum(u32) { _ };
pub const HalfEdgeIndex = enum(u32) { _ };
pub const LoopIndex = enum(u32) { _ };
pub const FaceIndex = enum(u32) { _ };
pub const ShellIndex = enum(u32) { _ };
pub const SolidIndex = enum(u32) { _ };

// --- Safe Null Sentinels ---
pub const NULL_VERTEX: VertexIndex = @fromBackingInt(std.math.maxInt(u32));
pub const NULL_HALF_EDGE: HalfEdgeIndex = @fromBackingInt(std.math.maxInt(u32));
pub const NULL_LOOP: LoopIndex = @fromBackingInt(std.math.maxInt(u32));
pub const NULL_FACE: FaceIndex = @fromBackingInt(std.math.maxInt(u32));
pub const NULL_SHELL: ShellIndex = @fromBackingInt(std.math.maxInt(u32));
pub const NULL_SOLID: SolidIndex = @fromBackingInt(std.math.maxInt(u32));

// --- Feature Lineage & CAD History Tracking ---
pub const AncestryTag = enum(u32) {
    untracked = 0,
    _,
};
