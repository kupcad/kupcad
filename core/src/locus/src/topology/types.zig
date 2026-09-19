const std = @import("std");

pub const VertexIndex = enum(u32) { _ };
pub const HalfEdgeIndex = enum(u32) { _ };
pub const LoopIndex = enum(u32) { _ };
pub const FaceIndex = enum(u32) { _ };
pub const ShellIndex = enum(u32) { _ };
pub const SolidIndex = enum(u32) { _ };

pub const NULL_HALF_EDGE = @as(HalfEdgeIndex, @enumFromInt(std.math.maxInt(u32)));
