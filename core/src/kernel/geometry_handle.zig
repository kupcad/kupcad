//! The types shared by both geometry engines and the code above them: `EngineType`, the
//! engine-tagged `GeometryHandle` and `CrossSectionHandle`, and plain results such as
//! `BoundingBox`, `Mesh` and `RayHit`.

const std = @import("std");

pub const EngineType = enum {
    manifold,
    brep_native,

    /// What scripts call the engine (`CAD.config(engine: :brep)`).
    pub fn scriptName(self: EngineType) []const u8 {
        return switch (self) {
            .manifold => "manifold",
            .brep_native => "brep",
        };
    }

    pub fn fromScriptName(name: []const u8) ?EngineType {
        for (std.enums.values(EngineType)) |engine| {
            if (std.mem.eql(u8, name, engine.scriptName())) return engine;
        }
        return null;
    }
};

/// A safe, tagged wrapper around C++ opaque pointers.
pub const GeometryHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};

pub const CrossSectionHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};

pub const Rect2D = struct {
    min: [2]f64,
    max: [2]f64,
};

/// A sketch's outlines as closed polylines: `points` holds every contour's vertices in turn
/// and `starts` where each begins, with the end after the last (one more entry than
/// contours). Outer contours run counter-clockwise, holes clockwise.
pub const Contours = struct {
    points: [][2]f64,
    starts: []u32,

    pub fn count(self: Contours) usize {
        return self.starts.len - 1;
    }

    pub fn contour(self: Contours, i: usize) [][2]f64 {
        return self.points[self.starts[i]..self.starts[i + 1]];
    }

    pub fn deinit(self: Contours, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.starts);
    }
};

pub const SolidPair = struct {
    first: ?GeometryHandle,
    second: ?GeometryHandle,
};

pub const BoundingBox = struct {
    min: [3]f64,
    max: [3]f64,
};

pub const FaceHandle = struct {
    index: u32,
    normal: [3]f64,
    centroid: [3]f64,
};

pub const Mesh = struct {
    vert_props: []f32,
    tri_verts: []u32,
    num_prop: usize,
};

pub const RayHit = struct {
    distance: f64,
    position: [3]f64,
    normal: [3]f64,
};
