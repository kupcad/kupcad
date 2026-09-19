const std = @import("std");

// --- Strictly Typed B-Rep Graph Indices ---
pub const VertexIndex = enum(u32) { _ };
pub const HalfEdgeIndex = enum(u32) { _ };
pub const LoopIndex = enum(u32) { _ };
pub const FaceIndex = enum(u32) { _ };
pub const ShellIndex = enum(u32) { _ };
pub const SolidIndex = enum(u32) { _ };

// --- Safe Null Sentinels ---
pub const NULL_VERTEX = @as(VertexIndex, @enumFromInt(std.math.maxInt(u32)));
pub const NULL_HALF_EDGE = @as(HalfEdgeIndex, @enumFromInt(std.math.maxInt(u32)));
pub const NULL_LOOP = @as(LoopIndex, @enumFromInt(std.math.maxInt(u32)));
pub const NULL_FACE = @as(FaceIndex, @enumFromInt(std.math.maxInt(u32)));
pub const NULL_SHELL = @as(ShellIndex, @enumFromInt(std.math.maxInt(u32)));
pub const NULL_SOLID = @as(SolidIndex, @enumFromInt(std.math.maxInt(u32)));

// --- Feature Lineage & CAD History Tracking ---
pub const AncestryTag = enum(u32) {
    untracked = 0,
    _,
};
