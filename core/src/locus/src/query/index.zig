//! The faces of a body indexed for the queries (docs/architecture.md §7.6, §12): each live
//! face's box grown by the zone, a BVH over them, and the body's box. Built once per body
//! and kept beside it by the host (a body never changes), so the viewer's ray at every
//! pointer move and a containment test cost a descent, not a pass over every face.

const std = @import("std");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const bbox = @import("../measure/bbox.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const FaceIndex = struct {
    /// The live faces, in the order the shells list them: item `i` of the BVH is
    /// `faces[i]`.
    faces: []types.FaceIndex,
    /// The body's box (not grown); empty for the empty body.
    box: Box3,
    bvh: bvh_mod.Bvh,

    /// The index of `body`'s faces, their boxes grown by the body's zone. Owned by
    /// `allocator`.
    pub fn build(allocator: std.mem.Allocator, body: *const Body, diag: *Diagnostics) Error!FaceIndex {
        var faces: std.ArrayList(types.FaceIndex) = .empty;
        defer faces.deinit(allocator);
        var boxes: std.ArrayList(Box3) = .empty;
        defer boxes.deinit(allocator);
        var box = Box3.empty;
        var shells = traverse.Shells.init(body);
        while (shells.next() catch return corrupt(diag)) |s| {
            var it = traverse.Faces.init(body, s);
            while (it.next() catch return corrupt(diag)) |f| {
                const face_box = bbox.faceBounds(body, f) catch return corrupt(diag);
                box = Box3.merge(box, face_box);
                try faces.append(allocator, f);
                try boxes.append(allocator, face_box.inflated(body.tol.zone));
            }
        }
        var tree = try bvh_mod.Bvh.build(allocator, boxes.items);
        errdefer tree.deinit(allocator);
        return .{ .faces = try faces.toOwnedSlice(allocator), .box = box, .bvh = tree };
    }

    pub fn deinit(self: *FaceIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.faces);
        self.bvh.deinit(allocator);
        self.* = undefined;
    }

    /// The grown box of item `i`'s face.
    pub fn boxOf(self: *const FaceIndex, i: u32) Box3 {
        return self.bvh.boxes[i];
    }
};

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
