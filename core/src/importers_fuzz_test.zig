//! Fuzzing what KupCAD reads but didn't write: an STL or font file a script imports, a package
//! archive and a provider's API response from the network, a WebSocket handshake from a
//! viewport client, and a cloned project's kupcad.lock, kupcad.json and .kupcad.json with
//! their version constraints. Each parser must take any bytes without crashing or leaking,
//! and keep what it promises of what it accepts: an STL mesh's faces point at its vertices
//! and every vertex is finite, a font's text outlines are finite, an archive's paths stay inside the package, a commit id is a
//! hex digest. A plain test run replays the seeds; `zig build fuzz -Dfuzz-target=importers
//! --fuzz=<runs>` searches from them.

const std = @import("std");
const testing = std.testing;
const support = @import("test_support.zig");
const stl = @import("exporters/3d/stl.zig");
const cafs_mod = @import("pkg/cafs.zig");
const Lockfile = @import("pkg/lockfile.zig").Lockfile;
const Manifest = @import("pkg/manifest.zig").Manifest;
const string_map = @import("pkg/string_map.zig");
const Fetcher = @import("pkg/providers/fetcher.zig").Fetcher;
const validate = @import("pkg/validate.zig");
const pkg_helpers = @import("pkg/test_helpers.zig");
const ProjectConfig = @import("cli/config.zig").ProjectConfig;
const semver = @import("core/semver.zig");
const viewport_ws = @import("cli/viewport_ws.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;
const text_mod = @import("core/text.zig");

/// The longest input the fuzzer makes for a parser.
const MAX_INPUT_BYTES = 16 * 1024;
const Buffer = [MAX_INPUT_BYTES]u8;

/// What an extracted fuzz archive may hold: small, so a run stays fast and its blobs few.
const FUZZ_EXTRACT_LIMITS: cafs_mod.ExtractLimits = .{ .max_total_bytes = 256 * 1024, .max_file_count = 32 };

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
