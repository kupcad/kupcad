//! Fuzzing what KupCAD reads but didn't write: an STL, OBJ, 3MF, DXF, SVG or font file a script imports, a package
//! archive and a provider's API response from the network, a WebSocket handshake from a
//! viewport client, and a cloned project's kupcad.lock, kupcad.json and .kupcad.json with
//! their version constraints. Each parser must take any bytes without crashing or leaking,
//! and keep what it promises of what it accepts: an STL mesh's faces point at its vertices
//! and every vertex is finite (mended too, core/mesh_repair.zig), a drawing's outlines and open paths are finite, a font's text outlines are finite, an archive's paths stay inside the package, a commit id is a
//! hex digest. A plain test run replays the seeds; `zig build fuzz -Dfuzz-target=importers
//! --fuzz=<runs>` searches from them.

const std = @import("std");
const testing = std.testing;
const support = @import("test_support.zig");
const stl = @import("exporters/3d/stl.zig");
const mesh_repair = @import("core/mesh_repair.zig");
const obj_read = @import("exporters/3d/obj_read.zig");
const threemf_read = @import("exporters/3d/threemf_read.zig");
const dxf_read = @import("exporters/2d/dxf_read.zig");
const svg_read = @import("exporters/2d/svg_read.zig");
const path_mod = @import("core/path.zig");
const zip = @import("exporters/zip.zig");
const cafs_mod = @import("pkg/cafs.zig");
const Lockfile = @import("pkg/lockfile.zig").Lockfile;
const Manifest = @import("pkg/manifest.zig").Manifest;
const string_map = @import("pkg/string_map.zig");
const Fetcher = @import("pkg/providers/fetcher.zig").Fetcher;
const validate = @import("pkg/validate.zig");
const pkg_helpers = @import("pkg/test_helpers.zig");
const ProjectConfig = @import("cli/config.zig").ProjectConfig;
const semver = @import("pkg/semver.zig");
const viewport_ws = @import("cli/viewport_ws.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;
const text_mod = @import("core/text.zig");

/// The longest input the fuzzer makes for a parser.
const MAX_INPUT_BYTES = 16 * 1024;
const Buffer = [MAX_INPUT_BYTES]u8;

/// What an extracted fuzz archive may hold: small, so a run stays fast and its blobs few.
const FUZZ_EXTRACT_LIMITS: cafs_mod.ExtractLimits = .{ .max_total_bytes = 256 * 1024, .max_file_count = 32 };

/// What a fuzzed drawing's blocks and clones may place, and read again: small, so a run
/// stays fast (the readers' own caps are what the limits test meets).
const FUZZ_DRAWING_POINTS = 10_000;
const FUZZ_DRAWING_BYTES = 256 * 1024;

/// Characters a font is asked for besides printable ASCII, which it draws: each cmap format a
/// font may map them with is read.
const FONT_PROBES = [_]u21{ 0xE9, 0x416, 0x2300, 0x4E2D, 0x1F600, 0x10FFFF };

const ASCII_STL =
    \\solid part
    \\  facet normal 0 0 1
    \\    outer loop
    \\      vertex 0 0 0
    \\      vertex 10 0 0
    \\      vertex 0 10 0
    \\    endloop
    \\  endfacet
    \\endsolid part
    \\
;

/// A binary STL of one triangle: an 80-byte header, the count, then a 50-byte record.
const BINARY_STL = blk: {
    var bytes: [84 + 50]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[80..84], 1, .little);
    const vertices = [_]f32{ 0, 0, 0, 10, 0, 0, 0, 10, 0 };
    for (vertices, 0..) |v, i| std.mem.writeInt(u32, bytes[84 + 12 + i * 4 ..][0..4], @bitCast(v), .little);
    break :blk bytes;
};

fn fuzzParser(comptime check: fn ([]const u8) anyerror!void, seeds: []const []const u8) !void {
    const buf = try testing.allocator.create(Buffer);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, struct {
        fn one(b: *Buffer, smith: *testing.Smith) anyerror!void {
            try check(b[0..smith.slice(b)]);
        }
    }.one, .{ .corpus = seeds });
}

// --- STL ---

test "fuzz: an STL file a script imports" {
    try fuzzParser(checkStl, &.{ ASCII_STL, &BINARY_STL, "solid empty\nendsolid empty\n" });
}

fn checkStl(data: []const u8) !void {
    var mesh = stl.parseStlBuffer(testing.allocator, data) catch return;
    defer mesh.deinit(testing.allocator);
    // The mesh goes to the kernel, which indexes the points by the faces and computes on them
    for (mesh.faces) |face| for (face) |index| try testing.expect(index < mesh.points.len);
    for (mesh.points) |point| for (point) |coordinate| try testing.expect(std.math.isFinite(coordinate));
    // Mended first, as the import does: whatever it makes still indexes its own points
    const fixed = try mesh_repair.repair(testing.allocator, .{ .points = mesh.points, .faces = mesh.faces }, 1e-5);
    defer fixed.deinit(testing.allocator);
    for (fixed.faces) |face| for (face) |index| try testing.expect(index < fixed.points.len);
}

// --- OBJ ---

test "fuzz: an OBJ file a script imports" {
    const cube = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\no box\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 3 4 8 7\nf 4 1 5 8\nf 2 3 7 6\n";
    try fuzzParser(checkObj, &.{ cube, "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 0 1\nf -3//1 -2//1 \\\n -1//1\n", "f 1 2 3\n" });
}

fn checkObj(data: []const u8) !void {
    var diag: obj_read.Diagnostic = .{};
    var model = obj_read.read(testing.allocator, data, &diag) catch return;
    defer model.deinit();
    // Each object's mesh goes to the kernel, as an STL's does
    try testing.expect(model.objects.len > 0);
    for (model.objects) |object| {
        for (object.mesh.faces) |face| for (face) |index| try testing.expect(index < object.mesh.points.len);
        for (object.mesh.points) |point| for (point) |coordinate| try testing.expect(std.math.isFinite(coordinate));
    }
}

// --- 3MF ---

test "fuzz: a 3MF package a script imports" {
    // A package of one triangle placed twice, one of them mirrored, and its model alone
    const model = "<model unit=\"inch\"><resources><object id=\"1\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/>" ++
        "<vertex x=\"0\" y=\"1\" z=\"0\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object>" ++
        "<object id=\"2\"><components><component objectid=\"1\" transform=\"-1 0 0 0 1 0 0 0 1 0 0 0\"/></components></object></resources>" ++
        "<build><item objectid=\"1\"/><item objectid=\"2\"/></build></model>";
    const package = try zip.write(testing.allocator, &.{ .{ .name = "_rels/.rels", .data = "<Relationships/>" }, .{ .name = "3D/3dmodel.model", .data = model } });
    defer testing.allocator.free(package);
    try fuzzParser(check3mf, &.{ package, model });
}

fn check3mf(data: []const u8) !void {
    var diag: threemf_read.Diagnostic = .{};
    var model = threemf_read.read(testing.allocator, data, &diag) catch return;
    defer model.deinit();
    // Each mesh goes to the kernel, as an STL's does
    try testing.expect(model.meshes.len > 0);
    for (model.meshes) |mesh| {
        for (mesh.faces) |face| for (face) |index| try testing.expect(index < mesh.points.len);
        for (mesh.points) |point| for (point) |coordinate| try testing.expect(std.math.isFinite(coordinate));
    }
}

// --- Fonts ---

test "fuzz: a font file a script imports" {
    // A TrueType font with a kern table, a CFF one with GPOS kerning (scripts/make-test-fonts.py),
    // and the start of each: their table directories alone
    const kern_table = @embedFile("core/test_fonts/kern-table.ttf");
    const gpos = @embedFile("core/test_fonts/gpos-kerning.otf");
    try fuzzParser(checkFont, &.{ kern_table, gpos, kern_table[0..200], gpos[0..200] });
}

fn checkFont(data: []const u8) !void {
    const face = text_mod.importedFace(data) catch return;
    for (FONT_PROBES) |probe| _ = face.glyph_index(probe);
    // The name a Font takes, decoded from the font's UTF-16: UTF-8 a String can hold
    if (try text_mod.fontName(testing.allocator, &face)) |name| {
        defer testing.allocator.free(name);
        try testing.expect(std.unicode.utf8ValidateSlice(name));
        try testing.expect(name.len <= text_mod.MAX_FONT_NAME_BYTES);
    }
    // What text() does with it: the printable ASCII it has, kerned, outlined and centred
    var sample: [0x7F - 0x20]u8 = undefined;
    var len: usize = 0;
    for (0x20..0x7F) |c| {
        if (face.glyph_index(@intCast(c)) == null) continue;
        sample[len] = @intCast(c);
        len += 1;
    }
    var polygons = try text_mod.extractText(testing.allocator, &face, sample[0..len], 10, 0.1, .center, .center);
    defer polygons.deinit(testing.allocator);
    // The outlines go to the kernel as polygons, which computes on them
    for (polygons.contours.items) |contour| for (contour.items) |point| for (point) |coordinate| {
        try testing.expect(std.math.isFinite(coordinate));
    };
}

// --- DXF and SVG ---

test "fuzz: a DXF drawing a script imports" {
    // Each entity that draws, a block placed in an array, and numbers far out of range
    const entities = "0\nLINE\n8\ncut\n10\n0\n20\n0\n11\n20\n21\n0\n0\nARC\n10\n20\n20\n5\n40\n5\n50\n270\n51\n90\n" ++
        "0\nLWPOLYLINE\n70\n1\n10\n0\n20\n0\n10\n10\n20\n0\n42\n1\n10\n10\n20\n10\n0\nCIRCLE\n10\n30\n20\n5\n40\n2\n" ++
        "0\nSPLINE\n71\n3\n10\n0\n20\n0\n10\n1\n20\n1\n10\n2\n20\n0\n10\n3\n20\n1\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n40\n1\n" ++
        "0\nELLIPSE\n10\n0\n20\n0\n11\n2\n21\n0\n40\n0.5\n0\nPOLYLINE\n70\n1\n0\nVERTEX\n10\n0\n20\n0\n0\nVERTEX\n10\n1\n20\n0\n0\nVERTEX\n10\n0\n20\n1\n0\nSEQEND\n";
    const drawing = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nbolt\n10\n0\n20\n0\n0\nCIRCLE\n8\n0\n10\n0\n20\n0\n40\n1\n0\nENDBLK\n0\nENDSEC\n" ++
        "0\nSECTION\n2\nENTITIES\n" ++ entities ++ "0\nINSERT\n2\nbolt\n10\n4\n20\n0\n41\n2\n50\n30\n70\n3\n71\n2\n44\n10\n45\n10\n0\nENDSEC\n0\nEOF\n";
    const far = "0\nSECTION\n2\nENTITIES\n0\nARC\n10\n0\n20\n0\n40\n1e300\n50\n1e300\n51\n-1e300\n0\nLWPOLYLINE\n70\n1e30\n10\n1e300\n20\n0\n0\nENDSEC\n0\nEOF\n";
    try fuzzParser(checkDxf, &.{ drawing, far });
}

fn checkDxf(data: []const u8) !void {
    var diag: dxf_read.Diagnostic = .{};
    var drawing = dxf_read.read(testing.allocator, data, .{ .tolerance = 1e-3, .keep_open = true, .max_points = FUZZ_DRAWING_POINTS }, &diag) catch return;
    defer drawing.deinit();
    try expectFinite(drawing.outlines);
    try expectFinite(drawing.open_paths);
}

test "fuzz: an SVG drawing a script imports" {
    // Each shape, a path of every command, a style sheet, and uses of a group and a symbol
    const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100mm\" height=\"50mm\" viewBox=\"0 0 200 100\"><defs><style>.c{fill:none}</style>" ++
        "<g id=\"g\"><rect x=\"1\" y=\"1\" width=\"5\" height=\"5\" rx=\"1\"/><circle cx=\"10\" cy=\"10\" r=\"3\"/></g>" ++
        "<symbol id=\"s\" viewBox=\"0 0 10 10\"><ellipse cx=\"5\" cy=\"5\" rx=\"4\" ry=\"2\"/></symbol></defs>" ++
        "<path d=\"M0 0L10 0H20V10C25 15 30 15 35 10S45 5 50 10Q55 15 60 10T70 10A5 5 0 0 1 80 10Z\" transform=\"rotate(30) scale(2 1)\"/>" ++
        "<polygon points=\"0,50 10,60 0,70\"/><polyline class=\"c\" points=\"20,50 30,60\"/><line x1=\"0\" y1=\"90\" x2=\"10\" y2=\"95\"/>" ++
        "<use href=\"#g\" x=\"100\"/><use href=\"#s\" x=\"150\" width=\"20\" height=\"20\"/></svg>";
    const deep = "<svg width=\"1mm\" viewBox=\"0 0 1 1\"><g id=\"a\"><use href=\"#b\"/></g><g id=\"b\"><use href=\"#a\"/></g></svg>";
    try fuzzParser(checkSvg, &.{ svg, deep });
}

fn checkSvg(data: []const u8) !void {
    var diag: svg_read.Diagnostic = .{};
    var drawing = svg_read.read(testing.allocator, data, .{ .tolerance = 1e-3, .max_cloned = FUZZ_DRAWING_POINTS, .max_reread = FUZZ_DRAWING_BYTES }, &diag) catch return;
    defer drawing.deinit();
    try expectFinite(drawing.outlines);
    try expectFinite(drawing.open_paths);
}

/// The kernel takes a drawing's runs as they are: each point of them is finite.
fn expectFinite(runs: []const path_mod.Run) !void {
    for (runs) |run| {
        for (run.start) |c| try testing.expect(std.math.isFinite(c));
        for (run.segments) |segment| {
            for (segment.to) |c| try testing.expect(std.math.isFinite(c));
            if (segment.arc) |arc| {
                for (arc.center) |c| try testing.expect(std.math.isFinite(c));
                try testing.expect(std.math.isFinite(arc.radius));
            }
            if (segment.cubic) |cubic| for ([_][2]f64{ cubic.c1, cubic.c2 }) |p| for (p) |c| {
                try testing.expect(std.math.isFinite(c));
            };
        }
    }
}

// --- Package archives ---

test "fuzz: a package archive downloaded for a dependency" {
    const archives = [_][]const pkg_helpers.TarEntry{
        &.{ .{ .name = "main.kup", .data = "export { part }\npart = cube(1)\n" }, .{ .name = "lib/screws.kup", .data = "x = 1\n" } },
        &.{ .{ .name = "repo-abc123/main.kup", .data = "cube(1)\n" }, .{ .name = "repo-abc123/README.md", .data = "# lib\n" } },
        &.{ .{ .name = "../escape.kup", .data = "x" }, .{ .name = "link", .kind = .symlink, .link = "/etc/passwd" } },
    };
    var seeds: [archives.len][]const u8 = undefined;
    for (archives, &seeds) |entries, *seed| seed.* = try pkg_helpers.buildTarGz(testing.allocator, entries);
    defer for (seeds) |seed| testing.allocator.free(seed);
    try fuzzParser(checkArchive, &seeds);
}

fn checkArchive(data: []const u8) !void {
    // A store of its own for each run: one shared over millions would fill the disk
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var project = MemoryVfs.init(testing.allocator);
    defer project.deinit();
    var store = try cafs_mod.Cafs.init(testing.allocator, testing.io, root, project.vfs());
    defer store.deinit();
    store.extract_limits = FUZZ_EXTRACT_LIMITS;

    const layout: cafs_mod.ArchiveLayout = if (data.len % 2 == 0) .flat else .wrapped;
    var reader: std.Io.Reader = .fixed(data);
    var archive = store.extractTarball(&reader, layout) catch return;
    defer archive.deinit(testing.allocator);
    try testing.expect(archive.files.count() <= FUZZ_EXTRACT_LIMITS.max_file_count);
    // Every path stays inside the package: sanitizing it again changes nothing
    var paths = archive.files.keyIterator();
    while (paths.next()) |path| {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings(path.*, try cafs_mod.sanitizeEntryPath(&buffer, path.*));
    }
}

// --- Network responses ---

test "fuzz: a provider's API response naming a commit" {
    try fuzzParser(checkCommitResponse, &.{
        "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}",
        "[{\"id\":\"89abcdef0123456789abcdef0123456789abcdef\"}]",
        "{\"sha\":\"../../etc\"}",
    });
}

fn checkCommitResponse(body: []const u8) !void {
    const sha = Fetcher.parseCommitShaResponse(testing.allocator, body) catch return;
    defer testing.allocator.free(sha);
    // It goes into paths and URLs
    try validate.validateCommitSha(sha);
}

test "fuzz: a WebSocket handshake from a viewport client" {
    try fuzzParser(checkHandshake, &.{
        "GET /viewport HTTP/1.1\r\nHost: localhost:9001\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: http://localhost\r\n\r\n",
        "GET / HTTP/1.1\r\nUpgrade: WebSocket\r\n\r\n",
    });
}

fn checkHandshake(request: []const u8) !void {
    const handshake = viewport_ws.parseHandshake(request) catch return;
    try testing.expectEqual(@as(usize, 24), handshake.key.len);
}

// --- A cloned project's files ---

test "fuzz: a project's kupcad.lock" {
    try fuzzParser(checkLockfile, &.{
        "{\"version\":\"1.0.0\",\"packages\":{\"github.com-a-b\":{\"resolved\":\"0123456789abcdef0123456789abcdef01234567\",\"ref\":\"main\",\"integrity\":\"sha256-abc\",\"dependencies\":{\"hw\":\"github.com/a/hw\"}}}}",
        "{\"version\":\"2.0.0\",\"packages\":{}}",
        "{ broken: true ",
    });
}

fn checkLockfile(content: []const u8) !void {
    const warnings = support.expectWarnings(); // an unsupported version is a warning, which the runner prints
    defer warnings.restore();
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    try files.vfs().writeFile("kupcad.lock", content);
    var lockfile = Lockfile.load(testing.allocator, files.vfs()) catch return;
    lockfile.deinit();
}

test "fuzz: a dependency's kupcad.json" {
    try fuzzParser(checkManifest, &.{
        "{\"name\":\"bolts\",\"version\":\"1.2.0\",\"dependencies\":{\"hw\":\"github.com/a/hw@v1.0.0\",\"local\":\"file:../x\"}}",
        "{\"dependencies\":[]}",
    });
}

fn checkManifest(json: []const u8) !void {
    var deps = Manifest.parseDependencies(testing.allocator, json) catch return;
    string_map.deinitOwned(testing.allocator, &deps);
}

test "fuzz: a project's .kupcad.json" {
    try fuzzParser(checkProjectConfig, &.{
        "{\"fmt\":{\"indent_width\":2,\"line_width\":100},\"lint\":{\"unused-variable\":\"off\",\"self-subtraction\":\"error\"},\"vm_memory_limit\":1000000}",
        "{\"lint\":{\"unused-variabel\":\"off\"}}",
    });
}

fn checkProjectConfig(source: []const u8) !void {
    var where: ProjectConfig.Position = undefined;
    _ = ProjectConfig.parse(testing.allocator, source, &where) catch return;
}

test "fuzz: a version or a version constraint" {
    try fuzzParser(checkSemver, &.{ "1.2.3", "v1.2", "^1.2.3", "~1.2", ">=2.0.0", "18446744073709551616.0.0" });
}

fn checkSemver(text: []const u8) !void {
    const version = semver.Version.parse(text) catch null;
    const constraint = semver.Constraint.parse(text) catch return;
    if (version) |v| _ = constraint.satisfies(v);
}
