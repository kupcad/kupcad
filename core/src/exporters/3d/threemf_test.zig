//! 3MF export (threemf.zig), read back: the package's files, one object per part and one
//! item per copy, each item placing its object's vertices where the kernel has that Solid's.

const std = @import("std");
const testing = std.testing;
const support = @import("../../test_support.zig");
const api = @import("../../api.zig");
const kernel = @import("../../kernel/kernel.zig");
const threemf = @import("threemf.zig");

/// A model's files, extracted by std.zip.
const Package = struct {
    tmp: testing.TmpDir,

    fn open(archive: []const u8) !Package {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "model.3mf", .data = archive });
        try tmp.dir.createDirPath(testing.io, "out");
        var out = try tmp.dir.openDir(testing.io, "out", .{});
        defer out.close(testing.io);
        const file = try tmp.dir.openFile(testing.io, "model.3mf", .{});
        defer file.close(testing.io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(testing.io, &buf);
        try std.zip.extract(out, &reader, .{});
        return .{ .tmp = tmp };
    }

    fn read(self: *Package, path: []const u8) ![]u8 {
        const full = try std.fs.path.join(testing.allocator, &.{ "out", path });
        defer testing.allocator.free(full);
        return self.tmp.dir.readFileAlloc(testing.io, full, testing.allocator, .limited(1 << 22));
    }

    fn close(self: *Package) void {
        self.tmp.cleanup();
    }
};

/// The value of attribute `name` in the XML element on `line`, or null.
fn attr(line: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = " " ++ name ++ "=\"";
    const start = (std.mem.find(u8, line, key) orelse return null) + key.len;
    const end = std.mem.findScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

fn number(line: []const u8, comptime name: []const u8) !f64 {
    return std.fmt.parseFloat(f64, attr(line, name) orelse return error.MissingAttribute);
}

/// The model's objects (their vertices, by id) and items (object id, transform), as the
/// writer lays them out: one element a line.
const Model = struct {
    vertices: std.AutoHashMapUnmanaged(u32, std.ArrayList([3]f64)) = .empty,
    items: std.ArrayList(struct { object: u32, m: [12]f64 }) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    colored_triangles: usize = 0,

    fn parse(xml: []const u8) !Model {
        var model: Model = .{};
        errdefer model.deinit();
        var current: ?u32 = null;
        var lines = std.mem.splitScalar(u8, xml, '\n');
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, "<object ") != null) {
                current = try std.fmt.parseInt(u32, attr(line, "id").?, 10);
                try model.vertices.put(testing.allocator, current.?, .empty);
                if (attr(line, "name")) |name| try model.names.append(testing.allocator, name);
            } else if (std.mem.find(u8, line, "<vertex ") != null) {
                const list = model.vertices.getPtr(current.?).?;
                try list.append(testing.allocator, .{ try number(line, "x"), try number(line, "y"), try number(line, "z") });
            } else if (std.mem.find(u8, line, "<triangle ") != null) {
                if (attr(line, "p1") != null) model.colored_triangles += 1;
            } else if (std.mem.find(u8, line, "<item ") != null) {
                var m: [12]f64 = undefined;
                var parts = std.mem.splitScalar(u8, attr(line, "transform").?, ' ');
                for (&m) |*entry| entry.* = try std.fmt.parseFloat(f64, parts.next().?);
                try model.items.append(testing.allocator, .{ .object = try std.fmt.parseInt(u32, attr(line, "objectid").?, 10), .m = m });
            }
        }
        return model;
    }

    fn deinit(self: *Model) void {
        var it = self.vertices.valueIterator();
        while (it.next()) |list| list.deinit(testing.allocator);
        self.vertices.deinit(testing.allocator);
        self.items.deinit(testing.allocator);
        self.names.deinit(testing.allocator);
    }
};

/// `points` sorted, so two vertex lists of one shape compare in any order.
fn sortPoints(points: [][3]f64) void {
    std.mem.sortUnstable([3]f64, points, {}, struct {
        fn lessThan(_: void, a: [3]f64, b: [3]f64) bool {
            for (a, b) |x, y| if (x != y) return x < y;
            return false;
        }
    }.lessThan);
}

/// Exports the model `source` leaves as 3MF and reads it back, checking every item puts its
/// object where the kernel puts the Solid it is a copy of.
fn exportAndCheck(source: []const u8) !struct { model: Model, xml: []u8 } {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    const archive = try api.exportModelFromVm(testing.allocator, &vm, .@"3mf", .{});
    defer testing.allocator.free(archive);
    var package = try Package.open(archive);
    defer package.close();
    const xml = try package.read(threemf.MODEL_PATH);
    errdefer testing.allocator.free(xml);
    for ([_][]const u8{ "[Content_Types].xml", "_rels/.rels" }) |path| testing.allocator.free(try package.read(path));
    var model = try Model.parse(xml);
    errdefer model.deinit();

    var collected = try api.collectModel(testing.allocator, &vm);
    defer collected.deinit(testing.allocator);
    const solids = collected.solids.items;
    try testing.expectEqual(solids.len, model.items.items.len);
    for (solids, model.items.items) |solid, item| {
        const mesh = kernel.getMesh(testing.allocator, try vm.ensureConcrete(solid)) orelse return error.NoMesh;
        defer testing.allocator.free(mesh.vert_props);
        defer testing.allocator.free(mesh.tri_verts);
        const expected = try testing.allocator.alloc([3]f64, mesh.vert_props.len / mesh.num_prop);
        defer testing.allocator.free(expected);
        for (expected, 0..) |*p, i| for (p, mesh.vert_props[i * mesh.num_prop ..][0..3]) |*c, v| {
            c.* = v;
        };
        const object = model.vertices.get(item.object).?.items;
        const placed = try testing.allocator.alloc([3]f64, object.len);
        defer testing.allocator.free(placed);
        // A point as a row, times the 4×3 matrix
        for (object, placed) |p, *q| for (0..3) |c| {
            q[c] = p[0] * item.m[c] + p[1] * item.m[3 + c] + p[2] * item.m[6 + c] + item.m[9 + c];
        };
        sortPoints(expected);
        sortPoints(placed);
        try testing.expectEqual(expected.len, placed.len);
        for (expected, placed) |e, q| for (e, q) |a, b| try testing.expectApproxEqAbs(a, b, 1e-4);
    }
    return .{ .model = model, .xml = xml };
}

test "3mf: a part is one object, each copy an item placing it where the kernel has it" {
    var got = try exportAndCheck(
        \\bolt = cylinder(r: 1, h: 6).named("M3 bolt")
        \\left = cube(x: 4, y: 2, z: 1).named("bracket")
        \\parts = [bolt, bolt.translate(5, 0, 0), bolt.rotate(30, 45, 60).translate(0, 7, 2), left, left.mirror(1, 0, 0)]
        \\assemble(name: "Pair & spares", parts: parts)
    );
    defer got.model.deinit();
    defer testing.allocator.free(got.xml);
    // The bolt once for its three copies; the mirrored bracket a part of its own
    try testing.expectEqual(@as(u32, 3), got.model.vertices.count());
    try testing.expectEqual(@as(usize, 5), got.model.items.items.len);
    try testing.expect(std.mem.find(u8, got.xml, "unit=\"millimeter\"") != null);
    try testing.expect(std.mem.find(u8, got.xml, "<metadata name=\"Title\">Pair &amp; spares</metadata>") != null);
    try testing.expectEqualStrings("M3 bolt", got.model.names.items[0]);
}

test "3mf: a Solid on its own is placed too, and its colour is its triangles' material" {
    var got = try exportAndCheck("cube(10).material(color: \"#FF8000\", alpha: 0.5).translate(5, 0, 0).rotate(0, 0, 90)");
    defer got.model.deinit();
    defer testing.allocator.free(got.xml);
    try testing.expectEqual(@as(u32, 1), got.model.vertices.count());
    try testing.expect(std.mem.find(u8, got.xml, "displaycolor=\"#FF800080\"") != null);
    // Every triangle of the cube has it
    try testing.expectEqual(@as(usize, 12), got.model.colored_triangles);
}

test "3mf: every part is written whole with a collection at every allocation" {
    // export.zig makes and evaluates every part (new Solids, with their materials) before
    // the package is written, holding them rooted; each still comes out whole and coloured
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm,
        \\a = cube(1).material(color: "#ff0000").named("a")
        \\b = cube(2).material(color: "#00ff00").named("b")
        \\c = cube(3).named("c")
        \\assemble(name: "kit", parts: [a, b, c, a.translate(5, 0, 0)])
    ));
    vm.gc.stress = true;
    const archive = try api.exportModelFromVm(testing.allocator, &vm, .@"3mf", .{});
    defer testing.allocator.free(archive);
    var package = try Package.open(archive);
    defer package.close();
    const xml = try package.read(threemf.MODEL_PATH);
    defer testing.allocator.free(xml);
    var model = try Model.parse(xml);
    defer model.deinit();
    try testing.expectEqual(@as(u32, 3), model.vertices.count());
    var meshes = model.vertices.valueIterator();
    while (meshes.next()) |list| try testing.expectEqual(@as(usize, 8), list.items.len);
    try testing.expectEqual(@as(usize, 4), model.items.items.len);
    try testing.expectEqual(@as(usize, 24), model.colored_triangles);
}

test "3mf: a model with no Solid is no file" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "x = 5"));
    try testing.expectError(error.RuntimeError, api.exportModelFromVm(testing.allocator, &vm, .@"3mf", .{}));
}
