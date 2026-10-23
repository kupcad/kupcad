//! `import_stl`, `import_obj` and `import_3mf`: a mesh file's Solid, in millimetres, each
//! mesh in it (an OBJ's objects, the meshes a 3MF's build places) a polyhedron node of the
//! geometry graph, united. The readers are exporters/3d/stl.zig, obj_read.zig and
//! threemf_read.zig. A mesh that isn't closed is mended first (core/mesh_repair.zig), as a
//! slicer mends what it imports, and a warning says what was changed; with `repair: false`
//! it is an ImportError instead, as is one that can't be mended, naming where it is open.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const arguments = @import("arguments.zig");
const Signature = @import("signature.zig").Signature;
const stl = @import("../exporters/3d/stl.zig");
const obj_read = @import("../exporters/3d/obj_read.zig");
const threemf_read = @import("../exporters/3d/threemf_read.zig");
const imported_mesh = @import("../exporters/3d/imported_mesh.zig");
const mesh_repair = @import("../core/mesh_repair.zig");
const Diagnostic = @import("../exporters/diagnostic.zig").Diagnostic;
const file_import = @import("file_import.zig");

const log = std.log.scoped(.vm);

/// A file's points are welded within this many of the float's steps at their size, at
/// least: what a file written from floats can't tell apart (STL holds f32).
const FLOAT_STEPS = 8;

pub const IMPORT_MESH = Signature{ .positional = &.{"path"}, .keywords = &.{"repair"} };

/// What a mesh import is given: the path, and whether to mend the mesh.
const Request = struct { path: []const u8, repair: bool };

fn requestOf(vm: *VM, args: []const value.Value, comptime method: []const u8, comptime file: []const u8) !Request {
    const parsed = try arguments.parseKwargsSubset(struct { repair: bool = true }, IMPORT_MESH.keywords, vm, args, method);
    if (parsed.positional.len != 1) return vm.fail(.ArgumentError, method ++ " expects the path of " ++ file, .{});
    return .{ .path = try arguments.requireName(vm, parsed.positional[0], method, "path"), .repair = parsed.opts.repair };
}

/// import_stl(path, repair:): the Solid of the STL file's triangles, binary or ASCII. What
/// `import logo from "./logo.stl"` calls.
pub fn nativeImportStl(vm: *VM, args: []const value.Value) !value.Value {
    const request = try requestOf(vm, args, "import_stl", "an STL file");
    const file = try file_import.read(vm, request.path, "STL", null);
    defer vm.allocator.free(file);
    const mesh = stl.parseStlBuffer(vm.allocator, file) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return vm.fail(.ImportError, "could not parse STL file '{s}': {s}", .{ request.path, @errorName(err) });
    };
    defer mesh.deinit(vm.allocator);
    return solidOf(vm, &.{mesh}, request, "import_stl", "STL");
}

/// import_obj(path, repair:): the Solid of the OBJ file's faces, each object (`o`) a mesh,
/// united. What `import bracket from "./bracket.obj"` calls.
pub fn nativeImportObj(vm: *VM, args: []const value.Value) !value.Value {
    const request = try requestOf(vm, args, "import_obj", "an OBJ file");
    const file = try file_import.read(vm, request.path, "OBJ", null);
    defer vm.allocator.free(file);
    var diag: Diagnostic = .{};
    var model = obj_read.read(vm.allocator, file, &diag) catch |err| return file_import.unreadable(vm, err, request.path, "OBJ", &diag);
    defer model.deinit();
    const meshes = try vm.allocator.alloc(imported_mesh.Mesh, model.objects.len);
    defer vm.allocator.free(meshes);
    for (model.objects, meshes) |object, *mesh| mesh.* = object.mesh;
    return solidOf(vm, meshes, request, "import_obj", "OBJ");
}

/// import_3mf(path, repair:): the Solid of what the 3MF package's build places, each copy
/// of an object's mesh where it is placed, united. What `import bracket from
/// "./bracket.3mf"` calls.
pub fn nativeImport3mf(vm: *VM, args: []const value.Value) !value.Value {
    const request = try requestOf(vm, args, "import_3mf", "a 3MF file");
    const file = try file_import.read(vm, request.path, "3MF", null);
    defer vm.allocator.free(file);
    var diag: Diagnostic = .{};
    var model = threemf_read.read(vm.allocator, file, &diag) catch |err| return file_import.unreadable(vm, err, request.path, "3MF", &diag);
    defer model.deinit();
    return solidOf(vm, model.meshes, request, "import_3mf", "3MF");
}

/// The Solid of `meshes`: a polyhedron node each, mended unless the request says not to,
/// united.
fn solidOf(vm: *VM, meshes: []const imported_mesh.Mesh, request: Request, comptime method: []const u8, comptime format: []const u8) !value.Value {
    const nodes = try vm.allocator.alloc(u32, meshes.len);
    defer vm.allocator.free(nodes);
    var mended: mesh_repair.Report = .{};
    for (meshes, nodes) |mesh, *node| {
        const given = mesh_repair.Mesh{ .points = mesh.points, .faces = mesh.faces };
        if (!request.repair) {
            const report = try mesh_repair.check(vm.allocator, given);
            if (!report.closed()) return notClosed(vm, report, request.path, format, "", "; " ++ method ++ "(path) mends what it can");
            node.* = try vm.dag_builder.addPolyhedron(mesh.points, mesh.faces);
            continue;
        }
        const fixed = try mesh_repair.repair(vm.allocator, given, weldTolerance(vm, mesh.points));
        defer fixed.deinit(vm.allocator);
        if (!fixed.report.closed()) return notClosed(vm, fixed.report, request.path, format, ", even mended", "");
        if (fixed.faces.len == 0) return vm.fail(.ImportError, "could not read " ++ format ++ " file '{s}': its mesh encloses no volume (triangles of a sheet, open all round, back to back with the patches that would close it)", .{request.path});
        mended.welded += fixed.report.welded;
        mended.dropped += fixed.report.dropped;
        mended.turned += fixed.report.turned;
        mended.filled += fixed.report.filled;
        node.* = try vm.dag_builder.addPolyhedron(fixed.points, fixed.faces);
    }
    if (mended.changed()) {
        var buffer: [256]u8 = undefined;
        log.warn(method ++ ": mended the mesh of '{s}' to close it: {s}", .{ request.path, changesOf(&buffer, mended) });
    }
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addBalancedChain(.union_op, nodes) });
}

/// How close two points of `points` can be and be welded: the active tolerance, or the
/// float's FLOAT_STEPS steps at the mesh's largest coordinate, whichever is more.
fn weldTolerance(vm: *VM, points: []const [3]f64) f64 {
    var largest: f64 = 0;
    for (points) |p| for (p) |c| {
        largest = @max(largest, @abs(c));
    };
    return @max(vm.config().tolerance, largest * std.math.floatEps(f32) * FLOAT_STEPS);
}

/// The ImportError of a mesh that isn't closed (`qualified`): what is wrong with it and
/// where, then the `hint`.
fn notClosed(vm: *VM, report: mesh_repair.Report, path: []const u8, comptime format: []const u8, comptime qualified: []const u8, comptime hint: []const u8) error{ RuntimeError, OutOfMemory } {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const faults = [_]struct { count: usize, text: []const u8 }{
        .{ .count = report.open_edges, .text = "on one triangle only" },
        .{ .count = report.shared_edges, .text = "on more than two triangles" },
        .{ .count = report.turned_edges, .text = "between triangles that face opposite ways" },
    };
    var listed: usize = 0;
    for (faults) |fault| {
        if (fault.count == 0) continue;
        w.print("{s}{d} {s} {s}", .{ if (listed == 0) "" else ", ", fault.count, if (fault.count == 1) "edge is" else "edges are", fault.text }) catch break;
        listed += 1;
    }
    const first = report.first.?;
    return vm.fail(.ImportError, "could not read " ++ format ++ " file '{s}': its mesh isn't closed" ++ qualified ++ ": {s}; the first from [{f}, {f}, {f}] to [{f}, {f}, {f}]" ++ hint, .{
        path,                         w.buffered(),
        value.fmtNumber(first[0][0]), value.fmtNumber(first[0][1]),
        value.fmtNumber(first[0][2]), value.fmtNumber(first[1][0]),
        value.fmtNumber(first[1][1]), value.fmtNumber(first[1][2]),
    });
}

/// What mending changed, as a list: "2 holes filled, 12 points welded".
fn changesOf(buffer: []u8, report: mesh_repair.Report) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    const changes = [_]struct { count: usize, one: []const u8, many: []const u8 }{
        .{ .count = report.filled, .one = "hole filled", .many = "holes filled" },
        .{ .count = report.welded, .one = "point welded", .many = "points welded" },
        .{ .count = report.turned, .one = "triangle turned around", .many = "triangles turned around" },
        .{ .count = report.dropped, .one = "triangle dropped (repeated or of no area)", .many = "triangles dropped (repeated or of no area)" },
    };
    var listed: usize = 0;
    for (changes) |change| {
        if (change.count == 0) continue;
        w.print("{s}{d} {s}", .{ if (listed == 0) "" else ", ", change.count, if (change.count == 1) change.one else change.many }) catch break;
        listed += 1;
    }
    return w.buffered();
}
