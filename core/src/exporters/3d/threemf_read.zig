//! 3MF import: `read` reads a 3D Manufacturing Format package, a zip (exporters/zip.zig)
//! of XML parts, as the meshes its build places, in millimetres. Each build item places the
//! object it names by its transform: a mesh, or components, other objects each placed by
//! its own transform within it, nested. The model is the part the package's relationships
//! (`_rels/.rels`) name as its 3D model (`3D/3dmodel.model` without them); an object of
//! another part of the package (the production extension's `p:path`, as slicers write a
//! project's objects) is read from that part. The root model's `unit` scales the whole to
//! millimetres. Only objects of the type `model` are read (not supports, nor `other`);
//! materials, colours, textures, beam lattices and slices are left out. A mirroring
//! transform turns its triangles around, so they still face out. The writer is threemf.zig.

const std = @import("std");
const imported_mesh = @import("imported_mesh.zig");
const zip = @import("../zip.zig");
const xml = @import("../xml.zig");
const limits = @import("../../core/limits.zig");
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// Where the 3D model is when the package's relationships don't say.
const DEFAULT_MODEL = "3D/3dmodel.model";
/// The package's relationships, and the type of the one that names the 3D model.
const RELATIONSHIPS = "_rels/.rels";
const MODEL_RELATIONSHIP = "/3dmodel";
/// How deep components nest in components at most: deeper is an object that holds itself.
const MAX_COMPONENT_NESTING = 64;
/// Millimetres in each `unit` a model can be in.
const UNIT_MM = std.StaticStringMap(f64).initComptime(.{
    .{ "micron", 0.001 },
    .{ "millimeter", 1 },
    .{ "centimeter", 10 },
    .{ "inch", 25.4 },
    .{ "foot", 304.8 },
    .{ "meter", 1000 },
});

/// The meshes the build places, each a copy of an object's mesh where it is placed, in
/// millimetres, owned by `arena`.
pub const Model = struct {
    meshes: []imported_mesh.Mesh,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }
};

pub const Error = error{Unreadable} || std.mem.Allocator.Error;

/// The meshes of the 3MF package `data`.
pub fn read(allocator: std.mem.Allocator, data: []const u8, diag: *Diagnostic) Error!Model {
    var model = Model{ .meshes = &.{}, .arena = .init(allocator) };
    errdefer model.deinit();
    const arena = model.arena.allocator();
    const archive = zip.Archive.open(arena, data) catch |err| return archiveError(err, "it", diag);
    var package = Package{ .arena = arena, .archive = archive, .diag = diag };
    const root = try package.part(try package.modelPath());
    if (root.items.len == 0) return diag.fail("{s}: its build places nothing", .{root.path});

    var placed: Placed = .{};
    for (root.items) |item| {
        placed = placed.plus(try package.countOf(try package.objectOf(root, item), 0));
        if (placed.meshes > limits.MAX_PLACED_MESHES) return diag.fail("its build would place more than {d} meshes; a script reads at most that", .{limits.MAX_PLACED_MESHES});
        if (placed.triangles > limits.MAX_PLACED_TRIANGLES) return diag.fail("its build would place more than {d} triangles; a script reads at most that", .{limits.MAX_PLACED_TRIANGLES});
        if (placed.vertices > limits.MAX_PLACED_VERTICES) return diag.fail("its build would place more than {d} vertices; a script reads at most that", .{limits.MAX_PLACED_VERTICES});
    }
    var meshes: std.ArrayList(imported_mesh.Mesh) = .empty;
    // The root's unit is the package's: a part of it is in the same one
    const scale = Affine.scaled(root.mm_per_unit);
    for (root.items) |item| try package.place(&meshes, try package.objectOf(root, item), item.transform.then(scale));
    if (meshes.items.len == 0) return diag.fail("{s}: its build places no mesh (only supports, or objects of no triangles)", .{root.path});
    model.meshes = meshes.items;
    return model;
}

/// An affine transform as a 3MF writes one: the rows of its 3×3 part, then its
/// translation, a point a row vector to its left (x' = x m00 + y m10 + z m20 + m30).
const Affine = struct {
    m: [4][3]f64,

    const identity = Affine{ .m = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, 0 } } };

    fn scaled(s: f64) Affine {
        return .{ .m = .{ .{ s, 0, 0 }, .{ 0, s, 0 }, .{ 0, 0, s }, .{ 0, 0, 0 } } };
    }

    /// This transform, then `outer`.
    fn then(self: Affine, outer: Affine) Affine {
        var out: Affine = undefined;
        for (0..4) |i| for (0..3) |j| {
            var sum: f64 = if (i == 3) outer.m[3][j] else 0;
            for (0..3) |k| sum += self.m[i][k] * outer.m[k][j];
            out.m[i][j] = sum;
        };
        return out;
    }

    fn apply(self: Affine, p: [3]f64) [3]f64 {
        var out: [3]f64 = undefined;
        for (0..3) |j| out[j] = p[0] * self.m[0][j] + p[1] * self.m[1][j] + p[2] * self.m[2][j] + self.m[3][j];
        return out;
    }

    /// Whether it mirrors: its 3×3 part's determinant is negative.
    fn mirrors(self: Affine) bool {
        const m = self.m;
        const det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
        return det < 0;
    }
};

/// A build item or a component: the object it places (of `path`, a part of the package,
/// or null for the one it is in), by `transform`, from the tag at `line`.
const Ref = struct { object: u32, transform: Affine, path: ?[]const u8, line: usize };

/// An object of a model part: its mesh (vertices and triangles) or its components, and
/// whether it is read (of the type `model`).
const Object = struct {
    part: *Part,
    vertices: std.ArrayList([3]f64) = .empty,
    triangles: std.ArrayList([3]u32) = .empty,
    components: std.ArrayList(Ref) = .empty,
    read: bool,
    /// What it places, its components' counted, once counted
    placed: ?Placed = null,
};

/// What a build places: the meshes, their triangles, and their vertices (each placement
/// welds an object's afresh, so a vertex is placed as many times as its object is).
const Placed = struct {
    meshes: u64 = 0,
    triangles: u64 = 0,
    vertices: u64 = 0,

    /// This and `other`, each sum held just past its limit: past it is past it.
    fn plus(self: Placed, other: Placed) Placed {
        return .{
            .meshes = @min(self.meshes + other.meshes, limits.MAX_PLACED_MESHES + 1),
            .triangles = @min(self.triangles + other.triangles, limits.MAX_PLACED_TRIANGLES + 1),
            .vertices = @min(self.vertices + other.vertices, limits.MAX_PLACED_VERTICES + 1),
        };
    }
};

/// A model part of the package: its objects by id, its build's items, its unit.
const Part = struct {
    path: []const u8,
    objects: std.AutoHashMapUnmanaged(u32, *Object) = .empty,
    items: []const Ref = &.{},
    mm_per_unit: f64 = 1,
};

const Package = struct {
    arena: std.mem.Allocator,
    archive: zip.Archive,
    diag: *Diagnostic,
    /// The model parts read, by path
    parts: std.StringHashMapUnmanaged(*Part) = .empty,
    /// What the parts read unpacked to, together: they all stay while the package is read,
    /// so many of them, each under the limit, were as much as memory held
    unpacked: usize = 0,

    /// Where the 3D model is: the relationship to it the package's relationships give, or
    /// the default.
    fn modelPath(self: *Package) Error![]const u8 {
        const entry = self.archive.find(RELATIONSHIPS) orelse return DEFAULT_MODEL;
        const text = try self.unpack(entry, RELATIONSHIPS);
        var scanner = xml.Scanner{ .text = text };
        while (try scanner.next(self.diag)) |tag| {
            if (tag.closing or !std.mem.eql(u8, xml.localName(tag.name), "Relationship")) continue;
            const kind = tag.attribute("Type") orelse continue;
            if (std.mem.endsWith(u8, kind, MODEL_RELATIONSHIP)) return tag.attribute("Target") orelse continue;
        }
        return DEFAULT_MODEL;
    }

    /// The model part at `path`, read the first time it is asked for.
    fn part(self: *Package, path: []const u8) Error!*Part {
        const name = std.mem.trimStart(u8, path, "/");
        if (self.parts.get(name)) |known| return known;
        const entry = self.archive.find(name) orelse return self.diag.fail("it has no {s}, the 3D model it names", .{name});
        const text = try self.unpack(entry, name);
        const p = try self.arena.create(Part);
        p.* = .{ .path = name };
        try self.parts.put(self.arena, name, p);
        try self.readPart(p, text);
        return p;
    }

    fn unpack(self: *Package, entry: zip.Archive.Entry, name: []const u8) Error![]const u8 {
        const text = self.archive.read(self.arena, entry, limits.MAX_PACKAGE_PART_BYTES - self.unpacked) catch |err| return archiveError(err, name, self.diag);
        self.unpacked += text.len;
        return text;
    }

    /// The objects and the build of the model part `p`, from its XML `text`.
    fn readPart(self: *Package, p: *Part, text: []const u8) Error!void {
        const diag = self.diag;
        var scanner = xml.Scanner{ .text = text };
        var items: std.ArrayList(Ref) = .empty;
        var object: ?*Object = null;
        var in_build = false;
        while (try scanner.next(diag)) |tag| {
            const name = xml.localName(tag.name);
            const line = xml.lineOf(text, tag.offset);
            if (tag.closing) {
                if (std.mem.eql(u8, name, "object")) object = null;
                if (std.mem.eql(u8, name, "build")) in_build = false;
                continue;
            }
            if (std.mem.eql(u8, name, "model")) {
                const unit = tag.attribute("unit") orelse "millimeter";
                p.mm_per_unit = UNIT_MM.get(unit) orelse return diag.fail("{s} line {d}: the unit \"{s}\" isn't one 3MF has", .{ p.path, line, unit });
            } else if (std.mem.eql(u8, name, "object")) {
                const id = try self.number(u32, tag, "id", p, line);
                const o = try self.arena.create(Object);
                o.* = .{ .part = p, .read = std.mem.eql(u8, tag.attribute("type") orelse "model", "model") };
                const entry = try p.objects.getOrPut(self.arena, id);
                if (entry.found_existing) return diag.fail("{s} line {d}: two objects have the id {d}", .{ p.path, line, id });
                entry.value_ptr.* = o;
                if (!tag.self_closing) object = o;
            } else if (std.mem.eql(u8, name, "build")) {
                in_build = !tag.self_closing;
            } else if (object) |o| {
                if (std.mem.eql(u8, name, "vertex")) {
                    var v: [3]f64 = undefined;
                    for (&v, [_][]const u8{ "x", "y", "z" }) |*c, axis| c.* = try self.coordinate(tag, axis, p, line);
                    try o.vertices.append(self.arena, v);
                } else if (std.mem.eql(u8, name, "triangle")) {
                    var t: [3]u32 = undefined;
                    for (&t, [_][]const u8{ "v1", "v2", "v3" }) |*corner, key| {
                        corner.* = try self.number(u32, tag, key, p, line);
                        if (corner.* >= o.vertices.items.len) return diag.fail("{s} line {d}: a triangle names vertex {d}, and its object has {d} before it", .{ p.path, line, corner.*, o.vertices.items.len });
                    }
                    try o.triangles.append(self.arena, t);
                } else if (std.mem.eql(u8, name, "component")) {
                    try o.components.append(self.arena, try self.refOf(tag, p, line));
                }
            } else if (in_build and std.mem.eql(u8, name, "item")) {
                try items.append(self.arena, try self.refOf(tag, p, line));
            }
        }
        p.items = items.items;
    }

    /// The object `ref` (in the part `in`) places.
    fn objectOf(self: *Package, in: *Part, ref: Ref) Error!*Object {
        const p = if (ref.path) |path| try self.part(path) else in;
        return p.objects.get(ref.object) orelse self.diag.fail("{s} line {d}: it places object {d}, which {s} hasn't", .{ in.path, ref.line, ref.object, p.path });
    }

    /// What `object` places, its components' counted (each object once).
    fn countOf(self: *Package, object: *Object, depth: usize) Error!Placed {
        if (object.placed) |known| return known;
        if (depth > MAX_COMPONENT_NESTING) return self.diag.fail("{s}: its objects hold objects more than {d} deep (does one hold itself?)", .{ object.part.path, MAX_COMPONENT_NESTING });
        var count: Placed = if (object.read and object.triangles.items.len > 0) .{ .meshes = 1, .triangles = object.triangles.items.len, .vertices = object.vertices.items.len } else .{};
        for (object.components.items) |component| {
            count = count.plus(try self.countOf(try self.objectOf(object.part, component), depth + 1));
        }
        object.placed = count;
        return count;
    }

    /// The meshes `object` places by `transform`, onto `meshes`.
    fn place(self: *Package, meshes: *std.ArrayList(imported_mesh.Mesh), object: *Object, transform: Affine) Error!void {
        if (object.read and object.triangles.items.len > 0) {
            var mesh: imported_mesh.Builder = .{};
            const mirrored = transform.mirrors();
            const index = try self.arena.alloc(u32, object.vertices.items.len);
            for (object.vertices.items, index) |v, *i| i.* = mesh.point(self.arena, transform.apply(v)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NonFiniteVertex => return self.diag.fail("{s}: a vertex placed by its transforms isn't finite", .{object.part.path}),
            };
            for (object.triangles.items) |t| {
                const corners = [3]u32{ index[t[0]], index[t[1]], index[t[2]] };
                try mesh.triangle(self.arena, if (mirrored) .{ corners[0], corners[2], corners[1] } else corners);
            }
            try meshes.append(self.arena, try mesh.finish(self.arena));
        }
        for (object.components.items) |component| {
            const placed = try self.objectOf(object.part, component);
            // One that places nothing (countOf has counted them all) isn't walked: empty objects'
            // components, layer upon layer, are ways down to nothing as many as they multiply to
            if (placed.placed.?.triangles == 0) continue;
            try self.place(meshes, placed, component.transform.then(transform));
        }
    }

    /// A build item's or a component's object, transform and part, from `tag`.
    fn refOf(self: *Package, tag: xml.Tag, p: *Part, line: usize) Error!Ref {
        var transform = Affine.identity;
        if (tag.attribute("transform")) |text| {
            var numbers = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
            for (0..4) |i| for (0..3) |j| {
                const word = numbers.next() orelse return self.diag.fail("{s} line {d}: the transform \"{s}\" isn't 12 numbers", .{ p.path, line, text });
                transform.m[i][j] = std.fmt.parseFloat(f64, word) catch return self.diag.fail("{s} line {d}: the transform \"{s}\" isn't 12 numbers", .{ p.path, line, text });
                if (!std.math.isFinite(transform.m[i][j])) return self.diag.fail("{s} line {d}: the transform \"{s}\" isn't finite", .{ p.path, line, text });
            };
            if (numbers.next() != null) return self.diag.fail("{s} line {d}: the transform \"{s}\" isn't 12 numbers", .{ p.path, line, text });
        }
        return .{ .object = try self.number(u32, tag, "objectid", p, line), .transform = transform, .path = tag.prefixedAttribute("path"), .line = line };
    }

    fn number(self: *Package, comptime T: type, tag: xml.Tag, key: []const u8, p: *Part, line: usize) Error!T {
        const text = tag.attribute(key) orelse return self.diag.fail("{s} line {d}: a <{s}> has no {s}", .{ p.path, line, tag.name, key });
        return std.fmt.parseInt(T, text, 10) catch self.diag.fail("{s} line {d}: the {s} \"{s}\" of a <{s}> isn't a whole number", .{ p.path, line, key, text, tag.name });
    }

    fn coordinate(self: *Package, tag: xml.Tag, key: []const u8, p: *Part, line: usize) Error!f64 {
        const text = tag.attribute(key) orelse return self.diag.fail("{s} line {d}: a vertex has no {s}", .{ p.path, line, key });
        const c = std.fmt.parseFloat(f64, text) catch return self.diag.fail("{s} line {d}: the vertex coordinate \"{s}\" isn't a number", .{ p.path, line, text });
        if (!std.math.isFinite(c)) return self.diag.fail("{s} line {d}: the vertex coordinate \"{s}\" isn't finite", .{ p.path, line, text });
        return c;
    }
};

/// What a zip reading error of `what` (the package, or a part of it) means, said.
fn archiveError(err: zip.ReadError, what: []const u8, diag: *Diagnostic) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAnArchive => diag.fail("it isn't a zip archive, which a 3MF package is", .{}),
        error.Corrupt => diag.fail("{s} is damaged: a record of the archive doesn't fit, or its data isn't what its checksum says", .{what}),
        error.Unsupported => diag.fail("{s} is stored in a way this reader doesn't read (zip64, encrypted, or packed but stored or deflated)", .{what}),
        error.TooLarge => diag.fail("{s} unpacks to more than {d} bytes; a script reads at most that", .{ what, limits.MAX_PACKAGE_PART_BYTES }),
    };
}
