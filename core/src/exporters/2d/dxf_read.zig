//! DXF import: `read` reads an ASCII DXF file's outlines in the XY plane as closed paths
//! (core/path.zig) in millimetres, scaled from the file's units (`$INSUNITS`). The
//! entities that draw outlines are read: a `LINE`, an `ARC` and a `CIRCLE` exact, an
//! `LWPOLYLINE` and a `POLYLINE` with their bulges as arcs, a `SPLINE` and an `ELLIPSE` as
//! the lines that keep within the resolution's chord error of them. Pieces whose ends meet
//! (within the tolerance) are joined, either way round, into outlines; one that can't be
//! closed is an open path when the reader keeps them (a laser's score line), else an error
//! naming where its ends are, and so is an entity off the XY plane. A block reference
//! (`INSERT`) places the entities its block (the BLOCKS section) defines, through its
//! insertion point, scale, rotation and array of copies, blocks within blocks too; an
//! entity on layer 0 in a block takes the INSERT's layer, as AutoCAD draws it. What isn't an outline (text, dimensions, hatches,
//! points, 3D faces and meshes) is left out, and so is what a layout draws (paper space).
//! The writer is dxf.zig.

const std = @import("std");
const path = @import("../../core/path.zig");
const EngineConfig = @import("../../core/engine_config.zig").EngineConfig;
const turnShare = @import("../../core/engine_config.zig").turnShare;
const affine2 = @import("../../core/affine2.zig");
const limits = @import("../../core/limits.zig");
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;

/// The layer of an entity that names none.
const DEFAULT_LAYER = "0";
/// What a binary DXF file starts with.
const BINARY_SENTINEL = "AutoCAD Binary DXF";
/// The highest degree of spline read: AutoCAD draws up to 11; the evaluation takes as many
/// points as the degree, and a corrupt one shouldn't ask for millions.
const MAX_SPLINE_DEGREE = 32;
/// How many times a spline's knot span is halved at most, finding its lines.
const MAX_SPLINE_DEPTH = 16;
/// A normal this close to ±z (per component) is the XY plane's, as AutoCAD's arbitrary
/// axis algorithm has it (1/64).
const PLANE_SLACK = 1.0 / 64.0;
/// How deep blocks nest in blocks at most: deeper is a block that inserts itself.
const MAX_BLOCK_NESTING = 64;
/// The entities that draw outlines.
const DRAWN = [_][]const u8{ "LINE", "ARC", "CIRCLE", "LWPOLYLINE", "POLYLINE", "SPLINE", "ELLIPSE" };

/// Millimetres in each `$INSUNITS` unit, by its code; 0 (unitless) is read as millimetres.
const UNIT_MM = [_]f64{
    1, // 0 unitless
    25.4, // 1 inches
    304.8, // 2 feet
    1_609_344, // 3 miles
    1, // 4 millimetres
    10, // 5 centimetres
    1000, // 6 metres
    1e6, // 7 kilometres
    25.4e-6, // 8 microinches
    0.0254, // 9 mils
    914.4, // 10 yards
    1e-7, // 11 angstroms
    1e-6, // 12 nanometres
    1e-3, // 13 microns
    100, // 14 decimetres
    1e4, // 15 decametres
    1e5, // 16 hectometres
    1e12, // 17 gigametres
    1.495978707e14, // 18 astronomical units
    9.4607304725808e18, // 19 light years
    3.0856775814913673e19, // 20 parsecs
    1200.0 / 3937.0 * 1000, // 21 US survey feet
};

pub const Options = struct {
    /// How far apart two ends can be and still meet.
    tolerance: f64,
    /// The layers read; null for every one.
    layers: ?[]const []const u8 = null,
    /// Whether pieces that join into no outline are open paths, not an error.
    keep_open: bool = false,
    /// How finely a spline and an ellipse are drawn.
    config: *const EngineConfig,
};

/// The outlines read, the open paths (kept, Options.keep_open) and every layer that holds
/// an entity read, in the order the file gives them; all owned by `arena`.
pub const Drawing = struct {
    outlines: []path.Run,
    open_paths: []path.Run,
    layers: []const []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Drawing) void {
        self.arena.deinit();
    }
};

pub const Error = error{InvalidDrawing} || std.mem.Allocator.Error;

/// The outlines of the DXF `text`, as `options` says.
pub fn read(allocator: std.mem.Allocator, text: []const u8, options: Options, diag: *Diagnostic) Error!Drawing {
    var drawing = Drawing{ .outlines = &.{}, .open_paths = &.{}, .layers = &.{}, .arena = .init(allocator) };
    errdefer drawing.deinit();
    if (std.mem.startsWith(u8, text, BINARY_SENTINEL)) return diag.fail("it is a binary DXF file: save it as an ASCII DXF", .{});
    var reader = Reader{ .arena = drawing.arena.allocator(), .pairs = .{ .text = text }, .options = options, .diag = diag };
    try reader.readSections();
    try reader.drawModel();
    drawing.outlines = try reader.joined();
    drawing.open_paths = reader.open_paths.items;
    drawing.layers = reader.layers.items;
    return drawing;
}

/// One group of the file: its code and its value, and the line its code is on.
const Pair = struct { code: i32, value: []const u8, line: usize };

const Pairs = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 0,
    peeked: ?Pair = null,

    fn next(self: *Pairs, diag: *Diagnostic) error{InvalidDrawing}!?Pair {
        if (self.peeked) |pair| {
            self.peeked = null;
            return pair;
        }
        const code_line = self.nextLine() orelse return null;
        const at = self.line;
        const code = std.fmt.parseInt(i32, std.mem.trim(u8, code_line, " \t"), 10) catch {
            return diag.fail("line {d}: '{s}' isn't a group code (an ASCII DXF file alternates codes and values)", .{ at, code_line[0..@min(code_line.len, 40)] });
        };
        const value = self.nextLine() orelse return diag.fail("line {d}: group code {d} has no value", .{ at, code });
        return .{ .code = code, .value = value, .line = at };
    }

    fn peek(self: *Pairs, diag: *Diagnostic) error{InvalidDrawing}!?Pair {
        if (self.peeked == null) self.peeked = try self.next(diag);
        return self.peeked;
    }

    fn nextLine(self: *Pairs) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const end = std.mem.findScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const line = std.mem.trimEnd(u8, self.text[self.pos..end], "\r");
        self.pos = end + 1;
        self.line += 1;
        return line;
    }
};

/// A run of segments an entity drew, or several joined: a whole outline when `closed`.
const Piece = struct {
    start: [2]f64,
    segments: std.ArrayList(path.Segment),
    closed: bool,
    layer: []const u8,

    fn end(self: *const Piece) [2]f64 {
        return path.endOf(self.start, self.segments.items);
    }
};

/// The groups of one entity, from its type to the next entity.
const Entity = struct {
    kind: []const u8,
    pairs: []const Pair,
    line: usize,

    fn layer(self: Entity) []const u8 {
        return self.string(8) orelse DEFAULT_LAYER;
    }

    fn string(self: Entity, code: i32) ?[]const u8 {
        for (self.pairs) |pair| if (pair.code == code) return pair.value;
        return null;
    }

    fn number(self: Entity, code: i32, diag: *Diagnostic) error{InvalidDrawing}!?f64 {
        for (self.pairs) |pair| if (pair.code == code) return try numberOf(pair, diag);
        return null;
    }

    fn required(self: Entity, code: i32, diag: *Diagnostic) error{InvalidDrawing}!f64 {
        return try self.number(code, diag) orelse diag.fail("line {d}: the {s} has no group {d}", .{ self.line, self.kind, code });
    }

    /// Its normal (210, 220, 230): whether it is the XY plane's turned over (-z), which
    /// mirrors the entity's own x; another plane is an error.
    fn flipped(self: Entity, diag: *Diagnostic) error{InvalidDrawing}!bool {
        const x = try self.number(210, diag) orelse 0;
        const y = try self.number(220, diag) orelse 0;
        const z = try self.number(230, diag) orelse 1;
        if (@abs(x) < PLANE_SLACK and @abs(y) < PLANE_SLACK and z != 0) return z < 0;
        return diag.fail("line {d}: the {s} on layer '{s}' isn't in the XY plane (its normal is [{d}, {d}, {d}])", .{ self.line, self.kind, self.layer(), x, y, z });
    }
};

fn numberOf(pair: Pair, diag: *Diagnostic) error{InvalidDrawing}!f64 {
    const n = std.fmt.parseFloat(f64, std.mem.trim(u8, pair.value, " \t")) catch {
        return diag.fail("line {d}: group {d} should be a number, got '{s}'", .{ pair.line + 1, pair.code, pair.value[0..@min(pair.value.len, 40)] });
    };
    if (!std.math.isFinite(n)) return diag.fail("line {d}: group {d} isn't a finite number", .{ pair.line + 1, pair.code });
    return n;
}

const Reader = struct {
    arena: std.mem.Allocator,
    pairs: Pairs,
    options: Options,
    diag: *Diagnostic,
    /// Millimetres per unit of the file
    scale: f64 = 1,
    pieces: std.ArrayList(Piece) = .empty,
    open_paths: std.ArrayList(path.Run) = .empty,
    layers: std.ArrayList([]const u8) = .empty,
    /// The POLYLINE whose VERTEX entities are being read, until its SEQEND
    polyline: ?Polyline = null,
    /// The ENTITIES section's entities, and each block's, by its name
    model: std.ArrayList(Entity) = .empty,
    blocks: std.StringHashMapUnmanaged(Block) = .empty,
    /// How many pieces each block places, once counted
    block_pieces: std.StringHashMapUnmanaged(usize) = .empty,
    /// Where the entities being drawn go: the INSERTs they are in
    place: Placement = .{},

    /// A block's entities and the point of them its INSERTs place.
    const Block = struct { base: [2]f64, entities: []const Entity };

    /// What the INSERTs around an entity do to it: their matrix (millimetres to
    /// millimetres), whether it keeps circles circles (else an arc is drawn as its chords
    /// first), and the layer an entity on layer 0 takes.
    const Placement = struct {
        matrix: affine2.Matrix = affine2.identity,
        similar: bool = true,
        layer: ?[]const u8 = null,
    };

    const Polyline = struct {
        entity_line: usize,
        layer: []const u8,
        closed: bool,
        /// A mesh's vertices are read past, not drawn
        mesh: bool,
        flipped: bool,
        vertices: std.ArrayList(Vertex) = .empty,
    };

    const Vertex = struct { at: [2]f64, bulge: f64 };

    fn readSections(self: *Reader) Error!void {
        while (try self.pairs.next(self.diag)) |pair| {
            if (pair.code != 0) continue;
            if (std.mem.eql(u8, pair.value, "EOF")) return;
            if (!std.mem.eql(u8, pair.value, "SECTION")) continue;
            const name = try self.pairs.next(self.diag) orelse return;
            if (name.code != 2) continue;
            if (std.mem.eql(u8, name.value, "HEADER")) {
                try self.readHeader();
            } else if (std.mem.eql(u8, name.value, "BLOCKS")) {
                try self.readBlocks();
            } else if (std.mem.eql(u8, name.value, "ENTITIES")) {
                _ = try self.collectEntities(&self.model, "ENDSEC");
            } else try self.skipSection();
        }
    }

    /// Every entity the model's INSERTs place, counted before any is: a block within a
    /// block within a block can place more than a drawing holds.
    fn drawModel(self: *Reader) Error!void {
        const count = try self.piecesOf(self.model.items, 0);
        if (count > limits.MAX_DRAWING_PIECES) return self.diag.fail("its blocks would place {d} pieces; a script reads at most {d}", .{ count, limits.MAX_DRAWING_PIECES });
        try self.draw(self.model.items);
    }

    fn draw(self: *Reader, entities: []const Entity) Error!void {
        for (entities) |entity| {
            if (std.mem.eql(u8, entity.kind, "INSERT")) try self.drawInsert(entity) else try self.readEntity(entity);
        }
    }

    /// The entities of `entity`'s block, placed at its insertion point: the block's base
    /// there, scaled, turned, and copied along its array's columns and rows (in its own
    /// turned axes, unscaled), mirrored in x when its plane is turned over.
    fn drawInsert(self: *Reader, entity: Entity) Error!void {
        if (try entity.number(67, self.diag) == 1) return;
        const name, const block = try self.blockOf(entity);
        const flip = try entity.flipped(self.diag);
        const at = try self.point(entity, 10, false);
        const sx = try entity.number(41, self.diag) orelse 1;
        const sy = try entity.number(42, self.diag) orelse 1;
        if (sx == 0 or sy == 0) return self.diag.fail("line {d}: the INSERT of the block '{s}' scales it to nothing", .{ entity.line, name });
        const turn = try entity.number(50, self.diag) orelse 0;
        const columns, const rows = try self.copiesOf(entity);
        const column_step = (try entity.number(44, self.diag) orelse 0) * self.scale;
        const row_step = (try entity.number(45, self.diag) orelse 0) * self.scale;
        const outer = self.place;
        defer self.place = outer;
        const layer = self.layerOf(entity);
        for (0..rows) |r| for (0..columns) |c| {
            var m = affine2.compose(affine2.scaling(sx, sy), affine2.translation(-block.base[0], -block.base[1]));
            m = affine2.compose(affine2.translation(@as(f64, @floatFromInt(c)) * column_step, @as(f64, @floatFromInt(r)) * row_step), m);
            m = affine2.compose(affine2.translation(at[0], at[1]), affine2.compose(affine2.rotation(turn), m));
            if (flip) m = affine2.compose(affine2.scaling(-1, 1), m);
            const matrix = affine2.compose(outer.matrix, m);
            self.place = .{ .matrix = matrix, .similar = affine2.similarityScale(matrix) != null, .layer = layer };
            try self.draw(block.entities);
        };
    }

    /// The block an INSERT names, and the name.
    fn blockOf(self: *Reader, entity: Entity) Error!struct { []const u8, Block } {
        const name = entity.string(2) orelse return self.diag.fail("line {d}: an INSERT names no block (group 2)", .{entity.line});
        const block = self.blocks.get(name) orelse return self.diag.fail("line {d}: an INSERT of the block '{s}', which the file doesn't define", .{ entity.line, name });
        return .{ name, block };
    }

    /// An INSERT's columns and rows (an array of copies, MINSERT's), at least one each.
    fn copiesOf(self: *Reader, entity: Entity) Error!struct { usize, usize } {
        var counts: [2]usize = undefined;
        for ([_]i32{ 70, 71 }, &counts) |code, *count| {
            const n = try entity.number(code, self.diag) orelse 1;
            if (!(n >= 0 and n <= limits.MAX_PATTERN_COUNT)) return self.diag.fail("line {d}: an INSERT copies its block {d} times across, at most {d}", .{ entity.line, n, limits.MAX_PATTERN_COUNT });
            count.* = @max(1, @as(usize, @intFromFloat(n)));
        }
        return .{ counts[0], counts[1] };
    }

    /// How many pieces `entities` place, their INSERTs' blocks counted once each.
    fn piecesOf(self: *Reader, entities: []const Entity, depth: usize) Error!usize {
        var total: usize = 0;
        for (entities) |entity| {
            if (isOneOf(entity.kind, &DRAWN)) {
                total +|= 1;
                continue;
            }
            if (!std.mem.eql(u8, entity.kind, "INSERT")) continue;
            const name, const block = try self.blockOf(entity);
            if (depth >= MAX_BLOCK_NESTING) return self.diag.fail("line {d}: blocks nest deeper than {d} in the block '{s}', which may insert itself", .{ entity.line, MAX_BLOCK_NESTING, name });
            const each = self.block_pieces.get(name) orelse blk: {
                const n = try self.piecesOf(block.entities, depth + 1);
                try self.block_pieces.put(self.arena, name, n);
                break :blk n;
            };
            const columns, const rows = try self.copiesOf(entity);
            total +|= each *| columns *| rows;
        }
        return total;
    }

    /// The entities up to `end` (or the section's end, which says so: true), kept.
    fn collectEntities(self: *Reader, list: *std.ArrayList(Entity), end: []const u8) Error!bool {
        while (try self.pairs.next(self.diag)) |pair| {
            if (pair.code != 0) continue;
            if (std.mem.eql(u8, pair.value, "ENDSEC")) return true;
            if (std.mem.eql(u8, pair.value, end)) return false;
            try list.append(self.arena, try self.entityAt(pair));
        }
        return true;
    }

    /// The entity whose type is `pair`: its groups, up to the next entity, kept.
    fn entityAt(self: *Reader, pair: Pair) Error!Entity {
        var groups: std.ArrayList(Pair) = .empty;
        while (try self.pairs.peek(self.diag)) |group| {
            if (group.code == 0) break;
            try groups.append(self.arena, (try self.pairs.next(self.diag)).?);
        }
        return .{ .kind = pair.value, .pairs = groups.items, .line = pair.line };
    }

    /// Each BLOCK's entities, by its name, with its base point.
    fn readBlocks(self: *Reader) Error!void {
        while (try self.pairs.next(self.diag)) |pair| {
            if (pair.code != 0) continue;
            if (std.mem.eql(u8, pair.value, "ENDSEC")) return;
            if (!std.mem.eql(u8, pair.value, "BLOCK")) continue;
            const header = try self.entityAt(pair);
            const name = header.string(2) orelse return self.diag.fail("line {d}: a BLOCK has no name (group 2)", .{pair.line});
            const base = [2]f64{ (try header.number(10, self.diag) orelse 0) * self.scale, (try header.number(20, self.diag) orelse 0) * self.scale };
            var entities: std.ArrayList(Entity) = .empty;
            const section_ended = try self.collectEntities(&entities, "ENDBLK");
            try self.blocks.put(self.arena, name, .{ .base = base, .entities = entities.items });
            if (section_ended) return;
        }
    }

    fn skipSection(self: *Reader) Error!void {
        while (try self.pairs.next(self.diag)) |pair| {
            if (pair.code == 0 and std.mem.eql(u8, pair.value, "ENDSEC")) return;
        }
    }

    fn readHeader(self: *Reader) Error!void {
        while (try self.pairs.next(self.diag)) |pair| {
            if (pair.code == 0 and std.mem.eql(u8, pair.value, "ENDSEC")) return;
            if (pair.code != 9 or !std.mem.eql(u8, pair.value, "$INSUNITS")) continue;
            const units = try self.pairs.next(self.diag) orelse return;
            const code = std.fmt.parseInt(i64, std.mem.trim(u8, units.value, " \t"), 10) catch -1;
            if (code < 0 or code >= UNIT_MM.len) return self.diag.fail("line {d}: its units ($INSUNITS {s}) aren't a unit DXF names", .{ units.line + 1, units.value });
            self.scale = UNIT_MM[@intCast(code)];
        }
    }

    fn readEntity(self: *Reader, entity: Entity) Error!void {
        const kind = entity.kind;
        if (std.mem.eql(u8, kind, "VERTEX")) return self.readVertex(entity);
        if (std.mem.eql(u8, kind, "SEQEND")) return self.endPolyline();
        // A layout's (paper space: a title block, a viewport's frame), not the model's
        if (try entity.number(67, self.diag) == 1) return;
        if (!isOneOf(kind, &DRAWN)) return;
        const layer = try self.noteLayer(self.layerOf(entity));
        if (!self.selected(layer)) return;
        if (std.mem.eql(u8, kind, "LINE")) return self.readLine(entity, layer);
        if (std.mem.eql(u8, kind, "ARC")) return self.readArc(entity, layer);
        if (std.mem.eql(u8, kind, "CIRCLE")) return self.readCircle(entity, layer);
        if (std.mem.eql(u8, kind, "LWPOLYLINE")) return self.readLwPolyline(entity, layer);
        if (std.mem.eql(u8, kind, "POLYLINE")) return self.startPolyline(entity, layer);
        if (std.mem.eql(u8, kind, "SPLINE")) return self.readSpline(entity, layer);
        return self.readEllipse(entity, layer);
    }

    /// The layer `entity` is drawn on: its own, or for one on layer 0 in a block, its
    /// INSERT's.
    fn layerOf(self: *const Reader, entity: Entity) []const u8 {
        const own = entity.layer();
        if (std.mem.eql(u8, own, DEFAULT_LAYER)) if (self.place.layer) |layer| return layer;
        return own;
    }

    /// The layer's name as the drawing keeps it, the first time it is seen.
    fn noteLayer(self: *Reader, name: []const u8) ![]const u8 {
        for (self.layers.items) |known| if (std.mem.eql(u8, known, name)) return known;
        const kept = try self.arena.dupe(u8, name);
        try self.layers.append(self.arena, kept);
        return kept;
    }

    fn selected(self: *const Reader, layer: []const u8) bool {
        const wanted = self.options.layers orelse return true;
        for (wanted) |name| if (std.mem.eql(u8, name, layer)) return true;
        return false;
    }

    /// The point of groups `x` and `x + 10` of `entity`, in millimetres, mirrored in x when
    /// the entity's plane is turned over.
    fn point(self: *Reader, entity: Entity, x: i32, flip: bool) Error![2]f64 {
        const px = try entity.required(x, self.diag);
        const py = try entity.required(x + 10, self.diag);
        return .{ (if (flip) -px else px) * self.scale, py * self.scale };
    }

    /// The piece of `segments` from `start`, placed where the INSERTs around it put it: an
    /// arc an arc unless they scale it unevenly, which draws it as its chords first.
    fn addPiece(self: *Reader, layer: []const u8, start: [2]f64, segments: []const path.Segment, closed: bool) !void {
        if (segments.len == 0) return;
        var list: std.ArrayList(path.Segment) = .empty;
        const m = self.place.matrix;
        if (std.meta.eql(m, affine2.identity)) {
            try list.appendSlice(self.arena, segments);
            try self.pieces.append(self.arena, .{ .start = start, .segments = list, .closed = closed, .layer = layer });
            return;
        }
        var from = start;
        for (segments) |segment| {
            defer from = segment.to;
            const arc = segment.arc orelse {
                try list.append(self.arena, segment.transformed(m));
                continue;
            };
            if (self.place.similar) {
                try list.append(self.arena, segment.transformed(m));
                continue;
            }
            var points: std.ArrayList([2]f64) = .empty;
            const chords = turnShare(self.options.config.segmentsFor(arc.radius), segment.angle / (2 * std.math.pi));
            try path.appendPoints(self.arena, &points, from, &.{segment}, &.{chords}, null);
            for (points.items[1..]) |p| try list.append(self.arena, .{ .to = affine2.apply(m, p) });
        }
        try self.pieces.append(self.arena, .{ .start = affine2.apply(m, start), .segments = list, .closed = closed, .layer = layer });
    }

    fn readLine(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const from = try self.point(entity, 10, false);
        const to = try self.point(entity, 11, false);
        if (from[0] == to[0] and from[1] == to[1]) return;
        try self.addPiece(layer, from, &.{.{ .to = to }}, false);
    }

    fn readArc(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const flip = try entity.flipped(self.diag);
        const center = try self.point(entity, 10, flip);
        const radius = try self.radiusOf(entity);
        const start = try entity.required(50, self.diag);
        var end = try entity.required(51, self.diag);
        // Counter-clockwise from start to end, in the entity's own plane
        while (end <= start) end += 360;
        var segment = path.arcByAngles(.{ 0, 0 }, radius, start, end);
        var from = path.pointAt(segment.arc.?, start);
        if (flip) {
            // Mirrored in x: the arc runs the other way round
            segment = segment.transformed(.{ -1, 0, 0, 1, 0, 0 });
            from = .{ -from[0], from[1] };
        }
        segment = segment.transformed(.{ 1, 0, 0, 1, center[0], center[1] });
        try self.addPiece(layer, .{ from[0] + center[0], from[1] + center[1] }, &.{segment}, false);
    }

    fn readCircle(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const center = try self.point(entity, 10, try entity.flipped(self.diag));
        const radius = try self.radiusOf(entity);
        const halves = [_]path.Segment{ path.arcByAngles(center, radius, 0, 180), path.arcByAngles(center, radius, 180, 360) };
        try self.addPiece(layer, .{ center[0] + radius, center[1] }, &halves, true);
    }

    fn radiusOf(self: *Reader, entity: Entity) Error!f64 {
        const r = try entity.required(40, self.diag);
        if (!(r > 0)) return self.diag.fail("line {d}: the {s} on layer '{s}' has a radius of {d}", .{ entity.line, entity.kind, entity.layer(), r });
        return r * self.scale;
    }

    fn readLwPolyline(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const flip = try entity.flipped(self.diag);
        var vertices: std.ArrayList(Vertex) = .empty;
        // Each vertex is its x (10), its y (20), and the bulge (42) of the segment from it
        for (entity.pairs) |pair| switch (pair.code) {
            10 => try vertices.append(self.arena, .{ .at = .{ try numberOf(pair, self.diag) * self.scale, 0 }, .bulge = 0 }),
            20 => if (vertices.items.len > 0) {
                vertices.items[vertices.items.len - 1].at[1] = try numberOf(pair, self.diag) * self.scale;
            },
            42 => if (vertices.items.len > 0) {
                vertices.items[vertices.items.len - 1].bulge = try numberOf(pair, self.diag);
            },
            else => {},
        };
        if (flip) for (vertices.items) |*v| {
            v.at[0] = -v.at[0];
            v.bulge = -v.bulge;
        };
        const flags = try entity.number(70, self.diag) orelse 0;
        try self.addPolyline(layer, vertices.items, @mod(@as(i64, @intFromFloat(flags)), 2) == 1);
    }

    fn startPolyline(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const flags: i64 = @intFromFloat(try entity.number(70, self.diag) orelse 0);
        // 16 a polygon mesh, 64 a polyface mesh: surfaces, not outlines
        self.polyline = .{ .entity_line = entity.line, .layer = layer, .closed = flags & 1 != 0, .mesh = flags & (16 | 64) != 0, .flipped = try entity.flipped(self.diag) };
    }

    fn readVertex(self: *Reader, entity: Entity) Error!void {
        const polyline = &(self.polyline orelse return);
        if (polyline.mesh) return;
        const flags: i64 = @intFromFloat(try entity.number(70, self.diag) orelse 0);
        // 16: a spline's frame control point, not a point it passes
        if (flags & 16 != 0) return;
        const at = try self.point(entity, 10, polyline.flipped);
        const bulge = try entity.number(42, self.diag) orelse 0;
        try polyline.vertices.append(self.arena, .{ .at = at, .bulge = if (polyline.flipped) -bulge else bulge });
    }

    fn endPolyline(self: *Reader) Error!void {
        const polyline = self.polyline orelse return;
        self.polyline = null;
        if (polyline.mesh) return;
        try self.addPolyline(polyline.layer, polyline.vertices.items, polyline.closed);
    }

    /// The piece through `vertices`, each bulge the segment's from its vertex (a closed
    /// one's last back to the first); a segment of no length is left out.
    fn addPolyline(self: *Reader, layer: []const u8, vertices: []const Vertex, closed: bool) Error!void {
        if (vertices.len < 2) return;
        var segments: std.ArrayList(path.Segment) = .empty;
        const count = if (closed) vertices.len else vertices.len - 1;
        for (0..count) |i| {
            const from = vertices[i];
            const to = vertices[(i + 1) % vertices.len].at;
            if (from.at[0] == to[0] and from.at[1] == to[1]) continue;
            try segments.append(self.arena, bulgeSegment(from.at, to, from.bulge));
        }
        try self.addPiece(layer, vertices[0].at, segments.items, closed);
    }

    fn readSpline(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const degree_f = try entity.number(71, self.diag) orelse 3;
        if (!(degree_f >= 1 and degree_f <= MAX_SPLINE_DEGREE)) return self.diag.fail("line {d}: the SPLINE on layer '{s}' is of degree {d}: 1 to {d} are read", .{ entity.line, layer, degree_f, MAX_SPLINE_DEGREE });
        const degree: usize = @intFromFloat(degree_f);
        var knots: std.ArrayList(f64) = .empty;
        var weights: std.ArrayList(f64) = .empty;
        var controls: std.ArrayList([2]f64) = .empty;
        var fit_points: usize = 0;
        for (entity.pairs) |pair| switch (pair.code) {
            40 => try knots.append(self.arena, try numberOf(pair, self.diag)),
            41 => try weights.append(self.arena, try numberOf(pair, self.diag)),
            10 => try controls.append(self.arena, .{ try numberOf(pair, self.diag) * self.scale, 0 }),
            20 => if (controls.items.len > 0) {
                controls.items[controls.items.len - 1][1] = try numberOf(pair, self.diag) * self.scale;
            },
            11 => fit_points += 1,
            else => {},
        };
        const n = controls.items.len;
        if (n == 0) {
            if (fit_points > 0) return self.diag.fail("line {d}: the SPLINE on layer '{s}' is given by fit points alone, which aren't read yet: give it control points", .{ entity.line, layer });
            return self.diag.fail("line {d}: the SPLINE on layer '{s}' has no control points", .{ entity.line, layer });
        }
        if (n <= degree or knots.items.len != n + degree + 1) {
            return self.diag.fail("line {d}: the SPLINE on layer '{s}' has {d} knots for {d} control points of degree {d}: it needs {d}", .{ entity.line, layer, knots.items.len, n, degree, n + degree + 1 });
        }
        for (knots.items[1..], knots.items[0 .. knots.items.len - 1]) |k, before| {
            if (k < before) return self.diag.fail("line {d}: the SPLINE on layer '{s}' has knots out of order", .{ entity.line, layer });
        }
        const rational = weights.items.len == n;
        if (rational) for (weights.items) |w| {
            if (!(w > 0)) return self.diag.fail("line {d}: the SPLINE on layer '{s}' has a weight of {d}: they must be greater than zero", .{ entity.line, layer, w });
        };
        const spline = Spline{ .degree = degree, .knots = knots.items, .controls = controls.items, .weights = if (rational) weights.items else null };
        var points: std.ArrayList([2]f64) = .empty;
        try spline.appendPoints(self.arena, &points, self.options.config.chordError(spline.size() / 2));
        try self.addPoints(layer, points.items, false);
    }

    fn readEllipse(self: *Reader, entity: Entity, layer: []const u8) Error!void {
        const center = try self.point(entity, 10, false);
        const major = try self.point(entity, 11, false);
        const ratio = try entity.required(40, self.diag);
        const a = std.math.hypot(major[0], major[1]);
        if (!(a > 0) or !(ratio > 0 and ratio <= 1)) return self.diag.fail("line {d}: the ELLIPSE on layer '{s}' has a major axis of {d} and a ratio of {d}", .{ entity.line, layer, a, ratio });
        const start = try entity.number(41, self.diag) orelse 0;
        var end = try entity.number(42, self.diag) orelse 2 * std.math.pi;
        while (end <= start) end += 2 * std.math.pi;
        // The minor axis is the major turned a quarter about the normal: left of it about +z
        const flip = try entity.flipped(self.diag);
        const minor = [2]f64{ (if (flip) major[1] else -major[1]) * ratio, (if (flip) -major[0] else major[0]) * ratio };
        const sweep = end - start;
        const chords = turnShare(self.options.config.segmentsFor(a), sweep / (2 * std.math.pi));
        var points: std.ArrayList([2]f64) = .empty;
        try points.ensureTotalCapacity(self.arena, chords + 1);
        for (0..chords + 1) |k| {
            const t = start + sweep * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(chords));
            points.appendAssumeCapacity(.{ center[0] + @cos(t) * major[0] + @sin(t) * minor[0], center[1] + @cos(t) * major[1] + @sin(t) * minor[1] });
        }
        try self.addPoints(layer, points.items, false);
    }

    /// The piece of lines through `points`, those of no length left out.
    fn addPoints(self: *Reader, layer: []const u8, points: []const [2]f64, closed: bool) Error!void {
        var segments: std.ArrayList(path.Segment) = .empty;
        var at = points[0];
        for (points[1..]) |p| {
            if (p[0] == at[0] and p[1] == at[1]) continue;
            try segments.append(self.arena, .{ .to = p });
            at = p;
        }
        try self.addPiece(layer, points[0], segments.items, closed);
    }

    /// Every piece joined into outlines: a closed one as it is, the others end to end (one
    /// turned around where it meets the outline by its end) until each closes; one that
    /// can't is an open path when they are kept.
    fn joined(self: *Reader) Error![]path.Run {
        const tolerance = self.options.tolerance;
        var ends = try EndIndex.init(self.arena, self.pieces.items, tolerance);
        const used = try self.arena.alloc(bool, self.pieces.items.len);
        @memset(used, false);
        var outlines: std.ArrayList(path.Run) = .empty;
        for (self.pieces.items, 0..) |*piece, i| {
            if (used[i]) continue;
            used[i] = true;
            if (piece.closed) {
                try outlines.append(self.arena, .{ .start = piece.start, .segments = piece.segments.items });
                continue;
            }
            var chain = Piece{ .start = piece.start, .segments = .empty, .closed = false, .layer = piece.layer };
            try chain.segments.appendSlice(self.arena, piece.segments.items);
            // On from its end, then back from its start, until it closes or nothing meets it
            while (!near(chain.end(), chain.start, tolerance)) {
                if (ends.meeting(chain.end(), used)) |found| {
                    used[found.piece] = true;
                    try self.append(&chain, &self.pieces.items[found.piece], found.at_start);
                } else if (ends.meeting(chain.start, used)) |found| {
                    used[found.piece] = true;
                    try self.prepend(&chain, &self.pieces.items[found.piece], found.at_start);
                } else if (self.options.keep_open) {
                    break;
                } else {
                    const end = chain.end();
                    return self.diag.fail("an outline on layer '{s}' doesn't close: it runs from [{d}, {d}] to [{d}, {d}], {d} apart (import_dxf(path, tolerance:) joins ends that far apart, and paths: true reads open lines as Paths)", .{ chain.layer, chain.start[0], chain.start[1], end[0], end[1], std.math.hypot(end[0] - chain.start[0], end[1] - chain.start[1]) });
                }
            }
            if (!near(chain.end(), chain.start, tolerance)) {
                try self.open_paths.append(self.arena, .{ .start = chain.start, .segments = chain.segments.items });
                continue;
            }
            // Its last end on its start, exactly
            chain.segments.items[chain.segments.items.len - 1].to = chain.start;
            try outlines.append(self.arena, .{ .start = chain.start, .segments = chain.segments.items });
        }
        return outlines.items;
    }

    /// `piece` on from the end of `chain`: as it is when it meets it by its start, turned
    /// around when by its end.
    fn append(self: *Reader, chain: *Piece, piece: *const Piece, at_start: bool) !void {
        const segments = if (at_start) piece.segments.items else try path.reversed(self.arena, piece.start, piece.segments.items);
        try chain.segments.appendSlice(self.arena, segments);
    }

    /// `piece` before the start of `chain`: as it is when it meets it by its end, turned
    /// around when by its start.
    fn prepend(self: *Reader, chain: *Piece, piece: *const Piece, at_start: bool) !void {
        const start = if (at_start) piece.end() else piece.start;
        const segments = if (at_start) try path.reversed(self.arena, piece.start, piece.segments.items) else piece.segments.items;
        try chain.segments.insertSlice(self.arena, 0, segments);
        // Its last segment ends where the chain started; the chain now starts at its start
        chain.segments.items[segments.len - 1].to = chain.start;
        chain.start = start;
    }
};

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn near(a: [2]f64, b: [2]f64, tolerance: f64) bool {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]) <= tolerance;
}

/// The segment from `from` to `to` that a polyline's `bulge` describes: a line for 0, else
/// the arc whose sweep is 4 atan |bulge|, counter-clockwise when it is positive.
fn bulgeSegment(from: [2]f64, to: [2]f64, bulge: f64) path.Segment {
    if (bulge == 0) return .{ .to = to };
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const chord = std.math.hypot(dx, dy);
    // The centre is off the chord's middle along its left normal by (1 - b²) / 4b of
    // (-dy, dx): left for a short counter-clockwise arc, right for a long one
    const off = (1 - bulge * bulge) / (4 * bulge);
    const center = [2]f64{ (from[0] + to[0]) / 2 - dy * off, (from[1] + to[1]) / 2 + dx * off };
    const radius = chord * (1 + bulge * bulge) / (4 * @abs(bulge));
    return .{ .to = to, .arc = .{ .center = center, .radius = radius }, .ccw = bulge > 0, .angle = 4 * std.math.atan(@abs(bulge)) };
}

/// The ends of the open pieces on a grid of cells twice the tolerance wide, so the pieces
/// meeting a point are found among those in its cell and the cells around it.
const EndIndex = struct {
    cells: std.AutoHashMapUnmanaged([2]i64, std.ArrayList(End)) = .empty,
    cell: f64,
    tolerance: f64,
    arena: std.mem.Allocator,

    const End = struct { piece: u32, at_start: bool, point: [2]f64 };
    const Found = struct { piece: u32, at_start: bool };

    fn init(arena: std.mem.Allocator, pieces: []const Piece, tolerance: f64) !EndIndex {
        var index = EndIndex{ .cell = 2 * tolerance, .tolerance = tolerance, .arena = arena };
        for (pieces, 0..) |*piece, i| {
            if (piece.closed) continue;
            try index.add(.{ .piece = @intCast(i), .at_start = true, .point = piece.start });
            try index.add(.{ .piece = @intCast(i), .at_start = false, .point = piece.end() });
        }
        return index;
    }

    fn add(self: *EndIndex, end: End) !void {
        const entry = try self.cells.getOrPut(self.arena, self.cellOf(end.point));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.arena, end);
    }

    fn cellOf(self: *const EndIndex, p: [2]f64) [2]i64 {
        // Saturating: a point far out shares an edge cell, still compared by distance
        return .{ std.math.lossyCast(i64, @floor(p[0] / self.cell)), std.math.lossyCast(i64, @floor(p[1] / self.cell)) };
    }

    /// An end of a piece not yet `used` within the tolerance of `p`.
    fn meeting(self: *const EndIndex, p: [2]f64, used: []const bool) ?Found {
        const at = self.cellOf(p);
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i64 = -1;
            while (dy <= 1) : (dy += 1) {
                const ends = self.cells.get(.{ at[0] + dx, at[1] + dy }) orelse continue;
                for (ends.items) |end| {
                    if (!used[end.piece] and near(end.point, p, self.tolerance)) return .{ .piece = end.piece, .at_start = end.at_start };
                }
            }
        }
        return null;
    }
};

/// A B-spline of `degree` over `knots` (as many as its control points and its degree and
/// one more), rational when it has `weights`.
const Spline = struct {
    degree: usize,
    knots: []const f64,
    controls: []const [2]f64,
    weights: ?[]const f64,

    /// The diagonal of its control points' box: what it is drawn as finely as a circle of.
    fn size(self: Spline) f64 {
        var box: ?path.Bounds = null;
        for (self.controls) |c| path.Bounds.include(&box, c);
        return std.math.hypot(box.?.max[0] - box.?.min[0], box.?.max[1] - box.?.min[1]);
    }

    /// Its points from its first knot span's start to its last's end, each span halved
    /// until its chords keep within `chord_error` of it (at their middles), or
    /// MAX_SPLINE_DEPTH times.
    fn appendPoints(self: Spline, allocator: std.mem.Allocator, points: *std.ArrayList([2]f64), chord_error: f64) !void {
        const first = self.degree;
        const last = self.controls.len;
        try points.append(allocator, try self.at(allocator, self.knots[first]));
        for (first..last) |span| {
            const t0 = self.knots[span];
            const t1 = self.knots[span + 1];
            if (t1 <= t0) continue;
            // At least the halves of each span, so an S-bend inside one isn't a straight chord
            const mid = (t0 + t1) / 2;
            try self.appendPiece(allocator, points, t0, mid, chord_error, 0);
            try self.appendPiece(allocator, points, mid, t1, chord_error, 0);
        }
    }

    fn appendPiece(self: Spline, allocator: std.mem.Allocator, points: *std.ArrayList([2]f64), t0: f64, t1: f64, chord_error: f64, depth: usize) !void {
        const a = points.items[points.items.len - 1];
        const b = try self.at(allocator, t1);
        const mid = try self.at(allocator, (t0 + t1) / 2);
        const off = std.math.hypot(mid[0] - (a[0] + b[0]) / 2, mid[1] - (a[1] + b[1]) / 2);
        if (off > chord_error and depth < MAX_SPLINE_DEPTH) {
            try self.appendPiece(allocator, points, t0, (t0 + t1) / 2, chord_error, depth + 1);
            try self.appendPiece(allocator, points, (t0 + t1) / 2, t1, chord_error, depth + 1);
            return;
        }
        try points.append(allocator, b);
    }

    /// The point at `t` by de Boor's algorithm, in homogeneous coordinates for a rational one.
    fn at(self: Spline, allocator: std.mem.Allocator, t: f64) ![2]f64 {
        const p = self.degree;
        // The span t is in: the last k with knots[k] <= t, within the spline's range
        var k = p;
        while (k + 1 < self.controls.len and self.knots[k + 1] <= t) k += 1;
        const d = try allocator.alloc([3]f64, p + 1);
        defer allocator.free(d);
        for (d, 0..) |*point, j| {
            const c = self.controls[j + k - p];
            const w = if (self.weights) |weights| weights[j + k - p] else 1;
            point.* = .{ c[0] * w, c[1] * w, w };
        }
        for (1..p + 1) |r| {
            var j = p;
            while (j >= r) : (j -= 1) {
                const lo = self.knots[j + k - p];
                const hi = self.knots[j + 1 + k - r];
                const alpha = if (hi > lo) (t - lo) / (hi - lo) else 0;
                for (0..3) |axis| d[j][axis] = (1 - alpha) * d[j - 1][axis] + alpha * d[j][axis];
            }
        }
        return .{ d[p][0] / d[p][2], d[p][1] / d[p][2] };
    }
};
