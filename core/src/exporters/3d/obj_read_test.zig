const std = @import("std");
const testing = std.testing;
const obj_read = @import("obj_read.zig");

/// A unit cube's corners and its six faces as quads, each counter-clockwise from outside.
const CUBE = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\n" ++
    "f 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 3 4 8 7\nf 4 1 5 8\nf 2 3 7 6\n";

fn read(text: []const u8) !obj_read.Model {
    var diag: obj_read.Diagnostic = .{};
    return obj_read.read(testing.allocator, text, &diag) catch |err| {
        std.debug.print("obj: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: obj_read.Diagnostic = .{};
    try testing.expectError(error.Unreadable, obj_read.read(testing.allocator, text, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

test "OBJ read: a cube of quads is its 8 corners and 12 triangles" {
    var model = try read(CUBE);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 1), model.objects.len);
    try testing.expectEqualStrings("", model.objects[0].name);
    try testing.expectEqual(@as(usize, 8), model.objects[0].mesh.points.len);
    try testing.expectEqual(@as(usize, 12), model.objects[0].mesh.faces.len);
}

test "OBJ read: objects, every corner form, numbers counted back, comments and lines that go on" {
    // A second object of one triangle named by its last three vertices, with texture and
    // normal numbers, a colour after a vertex, a comment and a face split over two lines
    const text = "# made by hand\no cube\n" ++ CUBE ++ "o tab # the label\nv 2 0 0 0.5 0.5 0.5\nv 3 0 0\nv 2 1 0\nvt 0 0\nvn 0 0 1\n" ++
        "f -3/1/1 -2//1 \\\n  -1/1\n";
    var model = try read(text);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 2), model.objects.len);
    try testing.expectEqualStrings("cube", model.objects[0].name);
    try testing.expectEqualStrings("tab", model.objects[1].name);
    const tab = model.objects[1].mesh;
    try testing.expectEqual(@as(usize, 3), tab.points.len);
    try testing.expectEqual(@as(usize, 1), tab.faces.len);
    try testing.expectEqual([3]f64{ 2, 0, 0 }, tab.points[tab.faces[0][0]]);
    try testing.expectEqual([3]f64{ 2, 1, 0 }, tab.points[tab.faces[0][2]]);

    // A face may name a vertex given after it; one with no area is left out, and so is an
    // object with no face
    var later = try read("o empty\nf 1 2 3\nf 1 2 4\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 2 0 0\no none\n");
    defer later.deinit();
    try testing.expectEqual(@as(usize, 1), later.objects.len);
    try testing.expectEqual(@as(usize, 1), later.objects[0].mesh.faces.len);
}

test "OBJ read: what can't be read says why and where" {
    try expectRefused("v 0 0 0\nv 1 0 0\nf 1 2 3\n", "line 3: a face names vertex 3, and the file has 2");
    try expectRefused("v 0 0 0\nf 0 1 2\n", "line 2: a face names vertex 0; they count from 1");
    try expectRefused("v 0 0 0\nf -2 1 1\n", "line 2: a face names vertex -2, back past the first of the 1 read");
    try expectRefused("v 0 0\n", "line 1: a vertex needs its x, y and z");
    try expectRefused("v 0 zero 0\n", "line 1: the vertex coordinate \"zero\" isn't a number");
    try expectRefused("v 0 nan 0\n", "line 1: the vertex coordinate \"nan\" isn't finite");
    try expectRefused("v 0 0 0\nv 1 0 0\nf 1 2\n", "line 3: a face needs at least 3 corners, got 2");
    try expectRefused("v 0 0 0\nf 1 a 1\n", "line 2: the face corner \"a\" isn't a vertex's number");
    try expectRefused("# nothing\nv 0 0 0\n", "it has no faces");
}
