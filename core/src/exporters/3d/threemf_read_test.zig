const std = @import("std");
const testing = std.testing;
const threemf_read = @import("threemf_read.zig");
const zip = @import("../zip.zig");
const support = @import("../../test_support.zig");

/// A tetrahedron's mesh of corners (0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), its faces out.
const TETRA = "<mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/><vertex x=\"0\" y=\"0\" z=\"1\"/></vertices>" ++
    "<triangles><triangle v1=\"0\" v2=\"2\" v3=\"1\"/><triangle v1=\"0\" v2=\"1\" v3=\"3\"/><triangle v1=\"0\" v2=\"3\" v3=\"2\"/><triangle v1=\"1\" v2=\"2\" v3=\"3\"/></triangles></mesh>";

/// A model part of `resources` and `build`, in `unit`.
fn model(comptime unit: []const u8, comptime resources: []const u8, comptime build: []const u8) []const u8 {
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"" ++ unit ++ "\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:p=\"http://schemas.microsoft.com/3dmanufacturing/production/2015/06\">\n" ++
        "<resources>" ++ resources ++ "</resources>\n<build>" ++ build ++ "</build>\n</model>\n";
}

/// The 3MF package of `files`, read; the caller frees `package` and deinits the model.
fn read(files: []const zip.File, package: *[]u8) !threemf_read.Model {
    package.* = try zip.write(testing.allocator, files);
    errdefer testing.allocator.free(package.*);
    var diag: threemf_read.Diagnostic = .{};
    return threemf_read.read(testing.allocator, package.*, .{}, &diag) catch |err| {
        std.debug.print("3mf: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(files: []const zip.File, message: []const u8) !void {
    return expectRefusedWith(files, .{}, message);
}

fn expectRefusedWith(files: []const zip.File, options: threemf_read.Options, message: []const u8) !void {
    const package = try zip.write(testing.allocator, files);
    defer testing.allocator.free(package);
    try expectBytesRefused(package, options, message);
}

fn expectBytesRefused(package: []const u8, options: threemf_read.Options, message: []const u8) !void {
    var diag: threemf_read.Diagnostic = .{};
    try testing.expectError(error.Unreadable, threemf_read.read(testing.allocator, package, options, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

/// The volume a closed mesh encloses (the divergence theorem over its triangles).
fn volume(mesh: anytype) f64 {
    var six: f64 = 0;
    for (mesh.faces) |f| {
        const a = mesh.points[f[0]];
        const b = mesh.points[f[1]];
        const c = mesh.points[f[2]];
        six += a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
    }
    return six / 6;
}

test "3MF read: a build's items place their objects' meshes, in millimetres" {
    // In inches, the tetrahedron placed twice: as it is, and moved 10 along x
    var package: []u8 = undefined;
    var m = try read(&.{.{ .name = "3D/3dmodel.model", .data = model("inch", "<object id=\"1\" type=\"model\">" ++ TETRA ++ "</object>", "<item objectid=\"1\"/><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 10 0 0\"/>") }}, &package);
    defer testing.allocator.free(package);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.meshes.len);
    try testing.expectApproxEqAbs(25.4 * 25.4 * 25.4 / 6.0, volume(m.meshes[0]), 1e-9);
    try testing.expectEqual(@as(f64, 254), m.meshes[1].points[0][0]);
}

test "3MF read: components nest, their transforms compose, and a mirror turns the triangles around" {
    // Object 2 holds the tetrahedron scaled 2 and moved up 5; the build mirrors object 2
    // in x and holds it as it is
    const resources = "<object id=\"1\">" ++ TETRA ++ "</object>" ++
        "<object id=\"2\"><components><component objectid=\"1\" transform=\"2 0 0 0 2 0 0 0 2 0 0 5\"/></components></object>";
    var package: []u8 = undefined;
    var m = try read(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", resources, "<item objectid=\"2\" transform=\"-1 0 0 0 1 0 0 0 1 0 0 0\"/><item objectid=\"2\"/>") }}, &package);
    defer testing.allocator.free(package);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.meshes.len);
    for (m.meshes) |mesh| {
        // Still facing out: the volume positive, 8/6
        try testing.expectApproxEqAbs(8.0 / 6.0, volume(mesh), 1e-12);
        try testing.expectEqual(@as(f64, 5), mesh.points[0][2]);
    }
    try testing.expectEqual(@as(f64, -2), m.meshes[0].points[1][0]);
}

test "3MF read: components that place nothing aren't walked, however many and deep" {
    // An object of nothing, and four layers of 300 components each of the layer below: 300^4
    // ways down to nothing, beside the tetrahedron
    const layer = struct {
        fn of(comptime id: []const u8, comptime below: []const u8) []const u8 {
            return "<object id=\"" ++ id ++ "\"><components>" ++ support.repeat("<component objectid=\"" ++ below ++ "\"/>", 300) ++ "</components></object>";
        }
    };
    const resources = comptime "<object id=\"1\">" ++ TETRA ++ "</object><object id=\"10\"><components></components></object>" ++
        layer.of("11", "10") ++ layer.of("12", "11") ++ layer.of("13", "12") ++ layer.of("14", "13");
    var package: []u8 = undefined;
    var m = try read(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", resources, "<item objectid=\"1\"/><item objectid=\"14\"/>") }}, &package);
    defer testing.allocator.free(package);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.meshes.len);
}

test "3MF read: the model the relationships name, and an object in another part of the package" {
    // As a slicer writes a project: the root model's item holds a component of an object
    // in 3D/Objects/part.model (the production extension's p:path)
    const rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Target=\"/3D/main.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>";
    const root = model("millimeter", "<object id=\"7\"><components><component p:path=\"/3D/Objects/part.model\" objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 0 3 0\"/></components></object>", "<item objectid=\"7\"/>");
    const part = model("millimeter", "<object id=\"1\">" ++ TETRA ++ "</object><object id=\"2\" type=\"support\">" ++ TETRA ++ "</object>", "");
    var package: []u8 = undefined;
    var m = try read(&.{ .{ .name = "_rels/.rels", .data = rels }, .{ .name = "3D/main.model", .data = root }, .{ .name = "3D/Objects/part.model", .data = part } }, &package);
    defer testing.allocator.free(package);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.meshes.len);
    try testing.expectEqual(@as(f64, 3), m.meshes[0].points[0][1]);
}

test "3MF read: what can't be read says why and where" {
    const tetra = "<object id=\"1\">" ++ TETRA ++ "</object>";
    try expectRefused(&.{.{ .name = "a.txt", .data = "" }}, "it has no 3D/3dmodel.model, the 3D model it names");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", tetra, "") }}, "3D/3dmodel.model: its build places nothing");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", tetra, "<item objectid=\"4\"/>") }}, "3D/3dmodel.model line 4: it places object 4, which 3D/3dmodel.model hasn't");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("furlong", tetra, "<item objectid=\"1\"/>") }}, "3D/3dmodel.model line 2: the unit \"furlong\" isn't one 3MF has");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", "<object id=\"1\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"0\"/></triangles></mesh></object>", "") }}, "3D/3dmodel.model line 3: a triangle names vertex 1, and its object has 1 before it");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", tetra, "<item objectid=\"1\" transform=\"1 0 0\"/>") }}, "3D/3dmodel.model line 4: the transform \"1 0 0\" isn't 12 numbers");
    // An object that holds itself
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", "<object id=\"1\"><components><component objectid=\"1\"/></components></object>", "<item objectid=\"1\"/>") }}, "3D/3dmodel.model: its objects hold objects more than 64 deep (does one hold itself?)");
    try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", "<object id=\"1\" type=\"support\">" ++ TETRA ++ "</object>", "<item objectid=\"1\"/>") }}, "3D/3dmodel.model: its build places no mesh (only supports, or objects of no triangles)");
    try expectBytesRefused("solid x\nendsolid x\n", .{}, "it isn't a zip archive, which a 3MF package is");
    // Each of the reader's refusals, with its words
    const item = "<item objectid=\"1\"/>";
    const cases = [_]struct { resources: []const u8, build: []const u8 = item, message: []const u8 }{
        .{ .resources = tetra ++ tetra, .message = "3D/3dmodel.model line 3: two objects have the id 1" },
        .{ .resources = "<object>" ++ TETRA ++ "</object>", .message = "3D/3dmodel.model line 3: a <object> has no id" },
        .{ .resources = "<object id=\"1\"><mesh><vertices><vertex y=\"0\" z=\"0\"/></vertices></mesh></object>", .message = "3D/3dmodel.model line 3: a vertex has no x" },
        .{ .resources = "<object id=\"1\"><mesh><vertices><vertex x=\"1e999\" y=\"0\" z=\"0\"/></vertices></mesh></object>", .message = "3D/3dmodel.model line 3: the vertex coordinate \"1e999\" isn't finite" },
        .{ .resources = tetra, .build = "<item objectid=\"1\" transform=\"1e999 0 0 0 1 0 0 0 1 0 0 0\"/>", .message = "3D/3dmodel.model line 4: the transform \"1e999 0 0 0 1 0 0 0 1 0 0 0\" isn't finite" },
        // Each transform in range, their product not: a component's scale, then the item's
        .{ .resources = "<object id=\"2\">" ++ TETRA ++ "</object><object id=\"1\"><components><component objectid=\"2\" transform=\"1e300 0 0 0 1 0 0 0 1 0 0 0\"/></components></object>", .build = "<item objectid=\"1\" transform=\"1e300 0 0 0 1 0 0 0 1 0 0 0\"/>", .message = "3D/3dmodel.model: a vertex placed by its transforms isn't finite" },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("resources: {s}\n", .{case.resources});
        try expectRefused(&.{.{ .name = "3D/3dmodel.model", .data = model("millimeter", case.resources, case.build) }}, case.message);
    }
}

test "3MF read: a part damaged, stored oddly, or past what the parts may unpack to together is refused" {
    const tetra = "<object id=\"1\">" ++ TETRA ++ "</object>";
    const whole = model("millimeter", tetra, "<item objectid=\"1\"/>");
    const package = try zip.write(testing.allocator, &.{.{ .name = "3D/3dmodel.model", .data = whole }});
    defer testing.allocator.free(package);
    // The CRC-32 of the model (the local header's, at 14, and the central's, past the data)
    const damaged = try testing.allocator.dupe(u8, package);
    defer testing.allocator.free(damaged);
    const central = std.mem.lastIndexOf(u8, damaged, "PK\x01\x02").?;
    damaged[central + 16] +%= 1;
    try expectBytesRefused(damaged, .{}, "3D/3dmodel.model is damaged: a record of the archive doesn't fit, or its data isn't what its checksum says");
    // A method but stored or deflated (both headers say it)
    const odd = try testing.allocator.dupe(u8, package);
    defer testing.allocator.free(odd);
    std.mem.writeInt(u16, odd[8..10], 12, .little);
    std.mem.writeInt(u16, odd[central + 10 ..][0..2], 12, .little);
    try expectBytesRefused(odd, .{}, "3D/3dmodel.model is stored in a way this reader doesn't read (zip64, encrypted, or packed but stored or deflated)");
    // Two parts, each under the limit, more than it together: the second is refused
    const parted = model("millimeter", "<object id=\"1\"><components><component p:path=\"/3D/part.model\" objectid=\"1\"/></components></object>", "<item objectid=\"1\"/>");
    const limit = parted.len + whole.len - 1;
    const too_much = try std.fmt.allocPrint(testing.allocator, "3D/part.model unpacks to more than {d} bytes; a script reads at most that", .{limit});
    defer testing.allocator.free(too_much);
    try expectRefusedWith(&.{ .{ .name = "3D/3dmodel.model", .data = parted }, .{ .name = "3D/part.model", .data = whole } }, .{ .max_unpacked = limit }, too_much);
    // ... and read when they fit it
    const fits = try zip.write(testing.allocator, &.{ .{ .name = "3D/3dmodel.model", .data = parted }, .{ .name = "3D/part.model", .data = whole } });
    defer testing.allocator.free(fits);
    var diag: threemf_read.Diagnostic = .{};
    var both = try threemf_read.read(testing.allocator, fits, .{ .max_unpacked = parted.len + whole.len }, &diag);
    defer both.deinit();
    try testing.expectEqual(@as(usize, 1), both.meshes.len);
}
