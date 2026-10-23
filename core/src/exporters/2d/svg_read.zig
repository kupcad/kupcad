//! SVG import: `read` reads an SVG file's shapes as closed paths (core/path.zig) in
//! millimetres: `path`, `rect`, `circle`, `ellipse`, `polygon` and `polyline`, through
//! their own and their groups' `transform`s. A circle's arcs (a `circle`, a round `rect`'s
//! corners, a path's `A` of equal radii) stay arcs while the transforms keep circles
//! circles (else cubics); curves (`C`, `S`, `Q` and `T` raised to cubics, an ellipse's arcs
//! as cubic pieces of an eighth of a turn) stay cubics. A subpath is an outline when it closes
//! (`Z`, or its ends meet within the tolerance), or when its shape is filled (SVG closes
//! it for the fill); an open one that isn't filled is a stroke alone, with no area: an
//! open path of its own (a laser's score line). A `line` is one too. Text, images and what
//! isn't drawn (`defs`, `clipPath`, `display: none`) are left out. A `use` draws the
//! element it names (`href="#id"`, in `defs` or anywhere, a `symbol` as a group) where it
//! is, through its own transform and `x`, `y`, with the style it gives. The file's units become millimetres by
//! its `width` and `viewBox` (a user unit is a CSS pixel, 1/96 inch, without them), and
//! its y, which runs down the page, is turned over about its origin. The writer is svg.zig.

const std = @import("std");
const path = @import("../../core/path.zig");
const affine2 = @import("../../core/affine2.zig");
const bezier = @import("../../core/bezier.zig");
const limits = @import("../../core/limits.zig");
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;

/// Millimetres in a CSS pixel, SVG's user unit when the file says nothing else.
const MM_PER_PX = 25.4 / 96.0;
/// The units a length can be given in, as pixels.
const LENGTH_UNITS = [_]struct { suffix: []const u8, px: f64 }{
    .{ .suffix = "px", .px = 1 },
    .{ .suffix = "mm", .px = 96.0 / 25.4 },
    .{ .suffix = "cm", .px = 96.0 / 2.54 },
    .{ .suffix = "in", .px = 96 },
    .{ .suffix = "pt", .px = 96.0 / 72.0 },
    .{ .suffix = "pc", .px = 16 },
    .{ .suffix = "Q", .px = 96.0 / 25.4 / 4.0 },
};
/// Elements whose content isn't drawn as it stands (definitions, text, images, styles).
const UNDRAWN = std.StaticStringMap(void).initComptime(.{ .{"defs"}, .{"clipPath"}, .{"mask"}, .{"symbol"}, .{"marker"}, .{"pattern"}, .{"metadata"}, .{"title"}, .{"desc"}, .{"style"}, .{"script"}, .{"linearGradient"}, .{"radialGradient"}, .{"filter"}, .{"foreignObject"}, .{"text"}, .{"image"} });
/// Elements that only group what is in them.
const GROUPS = std.StaticStringMap(void).initComptime(.{ .{"g"}, .{"a"}, .{"switch"} });
/// How deep elements nest at most.
const MAX_NESTING = 256;
/// Radii this close (relatively) are one circle's.
const ROUND_SLACK = 1e-12;

pub const Options = struct {
    /// How far apart a subpath's ends can be and still close it.
    tolerance: f64,
    /// How many elements `use`s may draw: nested, they multiply.
    max_cloned: usize = limits.MAX_DRAWING_PIECES,
};

/// The outlines read (closed) and the open paths (strokes alone), each in the file's
/// order, owned by `arena`.
pub const Drawing = struct {
    outlines: []path.Run,
    open_paths: []path.Run,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Drawing) void {
        self.arena.deinit();
    }
};

pub const Error = error{InvalidDrawing} || std.mem.Allocator.Error;

/// The outlines of the SVG `text`, as `options` says.
pub fn read(allocator: std.mem.Allocator, text: []const u8, options: Options, diag: *Diagnostic) Error!Drawing {
    var drawing = Drawing{ .outlines = &.{}, .open_paths = &.{}, .arena = .init(allocator) };
    errdefer drawing.deinit();
    var reader = Reader{ .arena = drawing.arena.allocator(), .text = text, .options = options, .diag = diag };
    try reader.readElements();
    drawing.outlines = reader.outlines.items;
    drawing.open_paths = reader.open_paths.items;
    return drawing;
}

/// One tag of the file: a start tag (with its attributes' text), an end tag, or one that
/// is both (`<path/>`).
const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool,
    self_closing: bool,
    offset: usize,

    /// The value of the attribute `name`, as written.
    fn attribute(self: Tag, name: []const u8) ?[]const u8 {
        var rest = self.attributes;
        while (true) {
            rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
            const eq = std.mem.findScalar(u8, rest, '=') orelse return null;
            const key = std.mem.trim(u8, rest[0..eq], &std.ascii.whitespace);
            rest = std.mem.trimStart(u8, rest[eq + 1 ..], &std.ascii.whitespace);
            if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return null;
            const close = std.mem.findScalarPos(u8, rest, 1, rest[0]) orelse return null;
            if (std.mem.eql(u8, key, name)) return rest[1..close];
            rest = rest[close + 1 ..];
        }
    }

    /// A property of its `style` (`fill: none`), or else the attribute of that name: CSS
    /// wins over the presentation attribute.
    fn property(self: Tag, name: []const u8) ?[]const u8 {
        if (self.attribute("style")) |style| {
            var declarations = std.mem.splitScalar(u8, style, ';');
            while (declarations.next()) |declaration| {
                const colon = std.mem.findScalar(u8, declaration, ':') orelse continue;
                if (std.mem.eql(u8, std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace), name)) return std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace);
            }
        }
        return self.attribute(name);
    }
};

const Scanner = struct {
    text: []const u8,
    pos: usize = 0,

    /// The next tag, past text, comments, CDATA, processing instructions and the DOCTYPE.
    fn next(self: *Scanner, diag: *Diagnostic) error{InvalidDrawing}!?Tag {
        while (true) {
            const open = std.mem.findScalarPos(u8, self.text, self.pos, '<') orelse return null;
            const rest = self.text[open..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                self.pos = try self.past(open, "-->", "a comment", diag);
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                self.pos = try self.past(open, "]]>", "a CDATA section", diag);
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                self.pos = try self.past(open, "?>", "a processing instruction", diag);
            } else if (std.mem.startsWith(u8, rest, "<!")) {
                // A DOCTYPE, its internal subset in brackets
                const bracket = std.mem.findScalarPos(u8, self.text, open, '[');
                const close = std.mem.findScalarPos(u8, self.text, open, '>') orelse return diag.fail("line {d}: a declaration doesn't end", .{lineOf(self.text, open)});
                self.pos = if (bracket != null and bracket.? < close) try self.past(bracket.?, "]>", "a DOCTYPE", diag) else close + 1;
            } else return try self.tag(open, diag);
        }
    }

    fn past(self: *Scanner, from: usize, end: []const u8, what: []const u8, diag: *Diagnostic) error{InvalidDrawing}!usize {
        const at = std.mem.findPos(u8, self.text, from, end) orelse return diag.fail("line {d}: {s} doesn't end", .{ lineOf(self.text, from), what });
        return at + end.len;
    }

    fn tag(self: *Scanner, open: usize, diag: *Diagnostic) error{InvalidDrawing}!Tag {
        // The '>' that ends it, outside its quoted values
        var i = open + 1;
        var quote: ?u8 = null;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (quote) |q| {
                if (c == q) quote = null;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') break;
        } else return diag.fail("line {d}: a tag doesn't end", .{lineOf(self.text, open)});
        self.pos = i + 1;
        var body = self.text[open + 1 .. i];
        const closing = body.len > 0 and body[0] == '/';
        if (closing) body = body[1..];
        const self_closing = body.len > 0 and body[body.len - 1] == '/';
        if (self_closing) body = body[0 .. body.len - 1];
        const name_end = std.mem.findAny(u8, body, &std.ascii.whitespace) orelse body.len;
        return .{ .name = body[0..name_end], .attributes = body[name_end..], .closing = closing, .self_closing = self_closing, .offset = open };
    }
};

fn lineOf(text: []const u8, offset: usize) usize {
    return std.mem.countScalar(u8, text[0..offset], '\n') + 1;
}

/// What an open element gives the ones in it.
const Frame = struct {
    /// Its tag's name, which its end tag must give
    name: []const u8,
    /// From its user units to the drawing's millimetres, y turned over
    matrix: affine2.Matrix,
    filled: bool,
    /// Its content isn't drawn
    skipped: bool,
};

const Reader = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    options: Options,
    diag: *Diagnostic,
    outlines: std.ArrayList(path.Run) = .empty,
    open_paths: std.ArrayList(path.Run) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    seen_root: bool = false,
    /// Where each element with an `id` starts, for a `use` of it
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    /// The ids the `use`s being drawn name, innermost last
    using: std.ArrayList([]const u8) = .empty,
    /// The element about to be drawn is a `use`'s: a `symbol` is drawn as a group
    use_root: bool = false,
    /// How many elements `use`s have drawn
    cloned: usize = 0,

    fn readElements(self: *Reader) Error!void {
        var index = Scanner{ .text = self.text };
        while (try index.next(self.diag)) |tag| {
            if (tag.closing) continue;
            const id = tag.attribute("id") orelse continue;
            const entry = try self.ids.getOrPut(self.arena, id);
            if (!entry.found_existing) entry.value_ptr.* = tag.offset;
        }
        var scanner = Scanner{ .text = self.text };
        try self.readTags(&scanner, false);
        if (!self.seen_root) return self.diag.fail("it has no <svg> element", .{});
    }

    /// The elements `scanner` reads, into the open frames: all of them, or with `one`,
    /// the element its next tag starts and what it holds.
    fn readTags(self: *Reader, scanner: *Scanner, comptime one: bool) Error!void {
        const depth = self.frames.items.len;
        while (try scanner.next(self.diag)) |tag| {
            if (tag.closing) {
                if (self.frames.items.len == depth) return self.diag.fail("line {d}: </{s}> closes no element", .{ lineOf(self.text, tag.offset), tag.name });
                const open = self.frames.pop().?;
                if (!std.mem.eql(u8, open.name, tag.name)) return self.diag.fail("line {d}: </{s}> closes a <{s}>", .{ lineOf(self.text, tag.offset), tag.name, open.name });
                if (one and self.frames.items.len == depth) return;
                continue;
            }
            const frame = try self.frameOf(tag);
            if (!tag.self_closing) {
                if (self.frames.items.len >= MAX_NESTING) return self.diag.fail("line {d}: elements nest deeper than {d}", .{ lineOf(self.text, tag.offset), MAX_NESTING });
                try self.frames.append(self.arena, frame);
            } else if (one and self.frames.items.len == depth) return;
        }
    }

    /// The element a `use` names, drawn in `frame` (the use's, its x and y the last move).
    fn readUse(self: *Reader, tag: Tag, frame: Frame) Error!void {
        const line = lineOf(self.text, tag.offset);
        const href = tag.attribute("href") orelse tag.attribute("xlink:href") orelse return;
        if (href.len < 2 or href[0] != '#') return self.diag.fail("line {d}: a <use> of \"{s}\": only an element of the same file (\"#id\") is read", .{ line, href[0..@min(href.len, 60)] });
        const id = href[1..];
        const at = self.ids.get(id) orelse return self.diag.fail("line {d}: a <use> of \"#{s}\", which no element of the file is", .{ line, id });
        for (self.using.items) |outer| {
            if (std.mem.eql(u8, outer, id)) return self.diag.fail("line {d}: a <use> of \"#{s}\" within that element, which would draw itself forever", .{ line, id });
        }
        var placed = frame;
        placed.matrix = affine2.compose(frame.matrix, affine2.translation(try self.length(tag, "x") orelse 0, try self.length(tag, "y") orelse 0));
        try self.frames.append(self.arena, placed);
        defer _ = self.frames.pop();
        try self.using.append(self.arena, id);
        defer _ = self.using.pop();
        self.use_root = true;
        var scanner = Scanner{ .text = self.text, .pos = at };
        try self.readTags(&scanner, true);
    }

    /// The frame `tag` opens, its shape (if it is one) read on the way.
    fn frameOf(self: *Reader, tag: Tag) Error!Frame {
        const parent: Frame = if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1] else .{ .name = "", .matrix = affine2.identity, .filled = true, .skipped = false };
        var frame = parent;
        frame.name = tag.name;
        // A symbol a use draws is a group; anywhere else it is a definition
        const symbol_drawn = self.use_root and std.mem.eql(u8, tag.name, "symbol");
        self.use_root = false;
        if (parent.skipped) return frame;
        if (self.using.items.len > 0) {
            self.cloned += 1;
            if (self.cloned > self.options.max_cloned) return self.diag.fail("its <use>s would draw more than {d} elements; a script reads at most that", .{self.options.max_cloned});
        }
        // Another vocabulary's (Inkscape's sodipodi:namedview) isn't drawn
        const name = if (std.mem.startsWith(u8, tag.name, "svg:")) tag.name[4..] else tag.name;
        frame.skipped = true;
        if (std.mem.findScalar(u8, name, ':') != null or (UNDRAWN.has(name) and !symbol_drawn)) return frame;
        if (tag.property("display")) |display| {
            if (std.mem.eql(u8, display, "none")) return frame;
        }
        frame.skipped = false;
        if (symbol_drawn and tag.attribute("viewBox") != null) return self.diag.fail("line {d}: a <symbol> with a viewBox isn't read yet", .{lineOf(self.text, tag.offset)});
        if (std.mem.eql(u8, name, "svg")) frame.matrix = try self.viewport(tag, parent);
        if (tag.attribute("transform")) |transform| frame.matrix = affine2.compose(frame.matrix, try self.transformOf(tag, transform));
        if (tag.property("fill")) |fill| frame.filled = !std.mem.eql(u8, fill, "none");
        if (!self.seen_root) return self.diag.fail("line {d}: a <{s}> comes before the <svg> element", .{ lineOf(self.text, tag.offset), name });

        if (std.mem.eql(u8, name, "use")) {
            try self.readUse(tag, frame);
            // What a use holds (a title) isn't drawn
            frame.skipped = true;
        } else if (std.mem.eql(u8, name, "path")) {
            try self.readPath(tag, frame);
        } else if (std.mem.eql(u8, name, "rect")) {
            try self.readRect(tag, frame);
        } else if (std.mem.eql(u8, name, "circle")) {
            try self.readEllipse(tag, frame, "r", "r");
        } else if (std.mem.eql(u8, name, "ellipse")) {
            try self.readEllipse(tag, frame, "rx", "ry");
        } else if (std.mem.eql(u8, name, "polygon") or std.mem.eql(u8, name, "polyline")) {
            try self.readPoints(tag, frame, std.mem.eql(u8, name, "polygon"));
        } else if (std.mem.eql(u8, name, "line")) {
            try self.readLine(tag, frame);
        } else if (!std.mem.eql(u8, name, "svg") and !GROUPS.has(name) and !symbol_drawn) {
            // An element the drawing has no shape for (an animation, a filter's part)
            frame.skipped = true;
        }
        return frame;
    }

    /// The matrix of an `svg` element: the root's from its user units to millimetres (by
    /// its width over its viewBox's), y turned over; a nested one's moved to its x and y.
    fn viewport(self: *Reader, tag: Tag, parent: Frame) Error!affine2.Matrix {
        const line = lineOf(self.text, tag.offset);
        if (self.seen_root) {
            if (tag.attribute("viewBox") != null) return self.diag.fail("line {d}: a nested <svg> with a viewBox isn't read yet", .{line});
            const x = try self.length(tag, "x") orelse 0;
            const y = try self.length(tag, "y") orelse 0;
            return affine2.compose(parent.matrix, affine2.translation(x, y));
        }
        self.seen_root = true;
        var mm_per_unit: f64 = MM_PER_PX;
        if (tag.attribute("viewBox")) |box| {
            var numbers = Numbers{ .text = box };
            var values: [4]f64 = undefined;
            for (&values) |*v| v.* = numbers.number() orelse return self.diag.fail("line {d}: its viewBox \"{s}\" isn't four numbers", .{ line, box });
            if (!(values[2] > 0 and values[3] > 0)) return self.diag.fail("line {d}: its viewBox \"{s}\" has no area", .{ line, box });
            const width = try self.rootSize(tag, "width");
            const height = try self.rootSize(tag, "height");
            // Fitted whole, as preserveAspectRatio's default has it: the smaller scale
            if (width != null or height != null) {
                const sx = if (width) |w| w / values[2] else std.math.inf(f64);
                const sy = if (height) |h| h / values[3] else std.math.inf(f64);
                mm_per_unit = @min(sx, sy);
            }
        }
        return .{ mm_per_unit, 0, 0, -mm_per_unit, 0, 0 };
    }

    /// The root's `width` or `height` in millimetres; null without one, or with a
    /// percentage (a share of a page it doesn't know).
    fn rootSize(self: *Reader, tag: Tag, name: []const u8) Error!?f64 {
        const text = tag.attribute(name) orelse return null;
        if (std.mem.endsWith(u8, std.mem.trim(u8, text, &std.ascii.whitespace), "%")) return null;
        const px = try self.lengthOf(tag, name, text);
        if (!(px > 0)) return self.diag.fail("line {d}: its {s} \"{s}\" isn't greater than zero", .{ lineOf(self.text, tag.offset), name, text });
        return px * MM_PER_PX;
    }

    /// The attribute `name` of `tag` as a length in user units (pixels, from a unit given).
    fn length(self: *Reader, tag: Tag, name: []const u8) Error!?f64 {
        const text = tag.attribute(name) orelse return null;
        return try self.lengthOf(tag, name, text);
    }

    fn lengthOf(self: *Reader, tag: Tag, name: []const u8, text: []const u8) Error!f64 {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        var per: f64 = 1;
        var digits = trimmed;
        for (LENGTH_UNITS) |unit| {
            if (std.mem.endsWith(u8, trimmed, unit.suffix)) {
                per = unit.px;
                digits = trimmed[0 .. trimmed.len - unit.suffix.len];
                break;
            }
        }
        const n = std.fmt.parseFloat(f64, digits) catch return self.diag.fail("line {d}: the {s} \"{s}\" of a <{s}> isn't a length", .{ lineOf(self.text, tag.offset), name, text, tag.name });
        if (!std.math.isFinite(n)) return self.diag.fail("line {d}: the {s} of a <{s}> isn't finite", .{ lineOf(self.text, tag.offset), name, tag.name });
        return n * per;
    }

    /// A `transform` attribute's matrix: its functions applied right to left.
    fn transformOf(self: *Reader, tag: Tag, text: []const u8) Error!affine2.Matrix {
        var matrix = affine2.identity;
        var rest = text;
        while (true) {
            rest = std.mem.trimStart(u8, rest, ", \t\r\n");
            if (rest.len == 0) return matrix;
            const open = std.mem.findScalar(u8, rest, '(') orelse return self.badTransform(tag, text);
            const close = std.mem.findScalarPos(u8, rest, open, ')') orelse return self.badTransform(tag, text);
            const name = std.mem.trim(u8, rest[0..open], &std.ascii.whitespace);
            var numbers = Numbers{ .text = rest[open + 1 .. close] };
            var args: [6]f64 = undefined;
            var count: usize = 0;
            while (numbers.number()) |n| : (count += 1) {
                if (count == args.len) return self.badTransform(tag, text);
                args[count] = n;
            }
            if (!numbers.done()) return self.badTransform(tag, text);
            const step: affine2.Matrix = if (std.mem.eql(u8, name, "matrix") and count == 6)
                args
            else if (std.mem.eql(u8, name, "translate") and (count == 1 or count == 2))
                affine2.translation(args[0], if (count == 2) args[1] else 0)
            else if (std.mem.eql(u8, name, "scale") and (count == 1 or count == 2))
                affine2.scaling(args[0], if (count == 2) args[1] else args[0])
            else if (std.mem.eql(u8, name, "rotate") and count == 1)
                affine2.rotation(args[0])
            else if (std.mem.eql(u8, name, "rotate") and count == 3)
                affine2.compose(affine2.translation(args[1], args[2]), affine2.compose(affine2.rotation(args[0]), affine2.translation(-args[1], -args[2])))
            else if (std.mem.eql(u8, name, "skewX") and count == 1)
                .{ 1, 0, @tan(args[0] * std.math.pi / 180), 1, 0, 0 }
            else if (std.mem.eql(u8, name, "skewY") and count == 1)
                .{ 1, @tan(args[0] * std.math.pi / 180), 0, 1, 0, 0 }
            else
                return self.badTransform(tag, text);
            matrix = affine2.compose(matrix, step);
            rest = rest[close + 1 ..];
        }
    }

    fn badTransform(self: *Reader, tag: Tag, text: []const u8) error{InvalidDrawing} {
        return self.diag.fail("line {d}: the transform \"{s}\" of a <{s}> isn't one SVG has", .{ lineOf(self.text, tag.offset), text[0..@min(text.len, 60)], tag.name });
    }

    fn readPath(self: *Reader, tag: Tag, frame: Frame) Error!void {
        const data = tag.attribute("d") orelse return;
        var shape = Shape{ .reader = self, .frame = frame };
        var parser = PathData{ .numbers = .{ .text = data } };
        parser.read(&shape) catch |err| switch (err) {
            error.BadPathData => return self.diag.fail("line {d}: the path data of a <path> isn't SVG's at character {d}: \"{s}\"", .{ lineOf(self.text, tag.offset), parser.numbers.pos + 1, data[parser.numbers.pos..@min(data.len, parser.numbers.pos + 20)] }),
            else => |e| return e,
        };
        try shape.finish(false);
    }

    fn readRect(self: *Reader, tag: Tag, frame: Frame) Error!void {
        const x = try self.length(tag, "x") orelse 0;
        const y = try self.length(tag, "y") orelse 0;
        const w = try self.length(tag, "width") orelse 0;
        const h = try self.length(tag, "height") orelse 0;
        if (w < 0 or h < 0) return self.diag.fail("line {d}: a <rect> has a negative width or height", .{lineOf(self.text, tag.offset)});
        if (w == 0 or h == 0) return;
        // A radius given alone is both; each at most half the side
        const rx_given = try self.length(tag, "rx");
        const ry_given = try self.length(tag, "ry");
        const rx = @min(@abs(rx_given orelse ry_given orelse 0), w / 2);
        const ry = @min(@abs(ry_given orelse rx_given orelse 0), h / 2);
        var shape = Shape{ .reader = self, .frame = frame };
        if (rx == 0 or ry == 0) {
            try shape.moveTo(.{ x, y });
            try shape.lineTo(.{ x + w, y });
            try shape.lineTo(.{ x + w, y + h });
            try shape.lineTo(.{ x, y + h });
        } else {
            try shape.moveTo(.{ x + rx, y });
            try shape.lineTo(.{ x + w - rx, y });
            try shape.arcTo(rx, ry, 0, false, true, .{ x + w, y + ry });
            try shape.lineTo(.{ x + w, y + h - ry });
            try shape.arcTo(rx, ry, 0, false, true, .{ x + w - rx, y + h });
            try shape.lineTo(.{ x + rx, y + h });
            try shape.arcTo(rx, ry, 0, false, true, .{ x, y + h - ry });
            try shape.lineTo(.{ x, y + ry });
            try shape.arcTo(rx, ry, 0, false, true, .{ x + rx, y });
        }
        try shape.finish(true);
    }

    /// A `circle` (its `r` both radii) or an `ellipse`: two half turns.
    fn readEllipse(self: *Reader, tag: Tag, frame: Frame, comptime rx_name: []const u8, comptime ry_name: []const u8) Error!void {
        const cx = try self.length(tag, "cx") orelse 0;
        const cy = try self.length(tag, "cy") orelse 0;
        const rx = try self.length(tag, rx_name) orelse 0;
        const ry = try self.length(tag, ry_name) orelse 0;
        if (rx < 0 or ry < 0) return self.diag.fail("line {d}: a <{s}> has a negative radius", .{ lineOf(self.text, tag.offset), tag.name });
        if (rx == 0 or ry == 0) return;
        var shape = Shape{ .reader = self, .frame = frame };
        try shape.moveTo(.{ cx + rx, cy });
        try shape.arcTo(rx, ry, 0, false, true, .{ cx - rx, cy });
        try shape.arcTo(rx, ry, 0, false, true, .{ cx + rx, cy });
        try shape.finish(true);
    }

    /// A `line`: filled or not, it encloses nothing, so it is an open path.
    fn readLine(self: *Reader, tag: Tag, frame: Frame) Error!void {
        var stroke = frame;
        stroke.filled = false;
        var shape = Shape{ .reader = self, .frame = stroke };
        try shape.moveTo(.{ try self.length(tag, "x1") orelse 0, try self.length(tag, "y1") orelse 0 });
        try shape.lineTo(.{ try self.length(tag, "x2") orelse 0, try self.length(tag, "y2") orelse 0 });
        try shape.finish(false);
    }

    fn readPoints(self: *Reader, tag: Tag, frame: Frame, closed: bool) Error!void {
        const text = tag.attribute("points") orelse return;
        var numbers = Numbers{ .text = text };
        var shape = Shape{ .reader = self, .frame = frame };
        var first = true;
        while (numbers.number()) |x| {
            const y = numbers.number() orelse return self.diag.fail("line {d}: the points of a <{s}> are an odd count of numbers", .{ lineOf(self.text, tag.offset), tag.name });
            if (first) try shape.moveTo(.{ x, y }) else try shape.lineTo(.{ x, y });
            first = false;
        }
        if (!numbers.done()) return self.diag.fail("line {d}: the points of a <{s}> aren't all numbers", .{ lineOf(self.text, tag.offset), tag.name });
        try shape.finish(closed);
    }
};

/// The subpaths of one element, in its user units, each an outline once finished.
const Shape = struct {
    reader: *Reader,
    frame: Frame,
    start: [2]f64 = .{ 0, 0 },
    at: [2]f64 = .{ 0, 0 },
    segments: std.ArrayList(path.Segment) = .empty,
    open: bool = false,

    fn moveTo(self: *Shape, p: [2]f64) !void {
        try self.finish(false);
        self.start = p;
        self.at = p;
        self.open = true;
    }

    fn begin(self: *Shape) void {
        if (self.open) return;
        // A drawing command after a `Z` goes on from where the closed subpath started
        self.start = self.at;
        self.open = true;
    }

    fn lineTo(self: *Shape, p: [2]f64) !void {
        self.begin();
        if (p[0] == self.at[0] and p[1] == self.at[1]) return;
        try self.segments.append(self.reader.arena, .{ .to = p });
        self.at = p;
    }

    fn cubicTo(self: *Shape, c1: [2]f64, c2: [2]f64, p: [2]f64) !void {
        self.begin();
        try self.segments.append(self.reader.arena, path.curve(self.at, .{ .c1 = c1, .c2 = c2 }, p));
        self.at = p;
    }

    /// SVG's arc to `p`: of radii `rx` and `ry` turned `phi` degrees, the long way when
    /// `large`, the way of increasing angle when `sweep` (SVG's endpoint form, its F.6.5).
    fn arcTo(self: *Shape, rx_in: f64, ry_in: f64, phi: f64, large: bool, sweep: bool, p: [2]f64) !void {
        self.begin();
        const from = self.at;
        if (p[0] == from[0] and p[1] == from[1]) return;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0) return self.lineTo(p);
        const cos_phi = @cos(phi * std.math.pi / 180);
        const sin_phi = @sin(phi * std.math.pi / 180);
        const hx = (from[0] - p[0]) / 2;
        const hy = (from[1] - p[1]) / 2;
        const x1 = cos_phi * hx + sin_phi * hy;
        const y1 = -sin_phi * hx + cos_phi * hy;
        // Radii too small to reach are scaled up until they just do
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        const coef = (if (large != sweep) @as(f64, 1) else -1) * @sqrt(@max(0, num / den));
        const cx1 = coef * rx * y1 / ry;
        const cy1 = -coef * ry * x1 / rx;
        const center = [2]f64{ cos_phi * cx1 - sin_phi * cy1 + (from[0] + p[0]) / 2, sin_phi * cx1 + cos_phi * cy1 + (from[1] + p[1]) / 2 };
        const theta1 = std.math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
        var delta = std.math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta1;
        if (sweep and delta < 0) delta += 2 * std.math.pi;
        if (!sweep and delta > 0) delta -= 2 * std.math.pi;

        if (@abs(rx - ry) <= ROUND_SLACK * @max(rx, ry)) {
            try self.segments.append(self.reader.arena, .{ .to = p, .arc = .{ .center = center, .radius = rx }, .ccw = delta > 0, .angle = @abs(delta) });
            self.at = p;
            return;
        }
        // An ellipse's: cubic pieces of at most an eighth of a turn each
        const ellipse = bezier.Ellipse{ .center = center, .rx = rx, .ry = ry, .axis = .{ cos_phi, sin_phi } };
        var pieces = ellipse.arc(theta1, delta, self.at, p, bezier.arcPieceCount(delta));
        while (pieces.next()) |piece| try self.cubicTo(piece.cubic.c1, piece.cubic.c2, piece.to);
    }

    fn close(self: *Shape) !void {
        if (!self.open) return;
        try self.finishOpen(true);
        self.at = self.start;
    }

    /// Ends the subpath being drawn: an outline when `closed`, when its ends meet, or when
    /// it is filled; otherwise a stroke alone, an open path.
    fn finish(self: *Shape, closed: bool) !void {
        if (!self.open) return;
        try self.finishOpen(closed);
    }

    fn finishOpen(self: *Shape, closed: bool) !void {
        defer {
            self.segments = .empty;
            self.open = false;
        }
        if (self.segments.items.len == 0) return;
        const end = self.at;
        const meets = std.math.hypot(end[0] - self.start[0], end[1] - self.start[1]) <= self.reader.options.tolerance;
        if (!closed and !meets and !self.frame.filled) return self.reader.open_paths.append(self.reader.arena, try self.placed());
        if (meets) {
            self.segments.items[self.segments.items.len - 1].to = self.start;
        } else try self.segments.append(self.reader.arena, .{ .to = self.start });
        try self.reader.outlines.append(self.reader.arena, try self.placed());
    }

    /// The subpath in millimetres: its arcs kept when the matrix keeps a circle a circle
    /// (and cubics otherwise), its cubics (any matrix keeps one a cubic) with it.
    fn placed(self: *Shape) !path.Run {
        const arena = self.reader.arena;
        const m = self.frame.matrix;
        const keeps_circles = affine2.similarityScale(m) != null;
        var moved: std.ArrayList(path.Segment) = .empty;
        var from = self.start;
        for (self.segments.items) |segment| {
            defer from = segment.to;
            if (segment.arc != null and !keeps_circles) {
                for (try path.arcCubics(arena, from, segment)) |piece| try moved.append(arena, piece.transformed(m));
            } else try moved.append(arena, segment.transformed(m));
        }
        return .{ .start = affine2.apply(m, self.start), .segments = moved.items };
    }
};

/// Numbers in SVG's notation, one after another: separated by whitespace or a comma, or by
/// nothing where the next can't continue the last (`1-2`, `.5.5`).
const Numbers = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipSeparators(self: *Numbers) void {
        while (self.pos < self.text.len and (std.ascii.isWhitespace(self.text[self.pos]) or self.text[self.pos] == ',')) self.pos += 1;
    }

    fn done(self: *Numbers) bool {
        self.skipSeparators();
        return self.pos == self.text.len;
    }

    /// Whether a number comes next.
    fn ahead(self: *Numbers) bool {
        self.skipSeparators();
        if (self.pos == self.text.len) return false;
        const c = self.text[self.pos];
        return std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+';
    }

    fn number(self: *Numbers) ?f64 {
        if (!self.ahead()) return null;
        const start = self.pos;
        var i = self.pos;
        if (self.text[i] == '-' or self.text[i] == '+') i += 1;
        var dot = false;
        var digits = false;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (!digits) return null;
        // An exponent, only when digits follow it (`1e` would be a number then an `e`)
        if (i < self.text.len and (self.text[i] == 'e' or self.text[i] == 'E')) {
            var j = i + 1;
            if (j < self.text.len and (self.text[j] == '-' or self.text[j] == '+')) j += 1;
            if (j < self.text.len and std.ascii.isDigit(self.text[j])) {
                while (j < self.text.len and std.ascii.isDigit(self.text[j])) j += 1;
                i = j;
            }
        }
        const n = std.fmt.parseFloat(f64, self.text[start..i]) catch return null;
        if (!std.math.isFinite(n)) return null;
        self.pos = i;
        return n;
    }

    /// An arc's flag: `0` or `1`, which needs no separator after it.
    fn flag(self: *Numbers) ?bool {
        self.skipSeparators();
        if (self.pos == self.text.len) return null;
        const c = self.text[self.pos];
        if (c != '0' and c != '1') return null;
        self.pos += 1;
        return c == '1';
    }
};

/// A path's `d`: its commands and their numbers, drawn into a Shape.
const PathData = struct {
    numbers: Numbers,

    const ReadError = error{BadPathData} || std.mem.Allocator.Error;

    fn read(self: *PathData, shape: *Shape) ReadError!void {
        var command: ?u8 = null;
        // The last cubic's second control and the last quadratic's control, for S and T
        var last_c2: ?[2]f64 = null;
        var last_q: ?[2]f64 = null;
        while (true) {
            self.numbers.skipSeparators();
            if (self.numbers.pos == self.numbers.text.len) return;
            const c = self.numbers.text[self.numbers.pos];
            if (std.ascii.isAlphabetic(c)) {
                command = c;
                self.numbers.pos += 1;
            } else if (command == null or command.? == 'Z' or command.? == 'z') return error.BadPathData;
            const cmd = command.?;
            const relative = std.ascii.isLower(cmd);
            const base = if (relative) shape.at else [2]f64{ 0, 0 };
            var c2: ?[2]f64 = null;
            var q: ?[2]f64 = null;
            switch (std.ascii.toUpper(cmd)) {
                'M' => {
                    try shape.moveTo(try self.point(base));
                    // More pairs after a move are lines
                    command = if (relative) 'l' else 'L';
                },
                'Z' => try shape.close(),
                'L' => try shape.lineTo(try self.point(base)),
                'H' => try shape.lineTo(.{ try self.coordinate() + base[0], shape.at[1] }),
                'V' => try shape.lineTo(.{ shape.at[0], try self.coordinate() + base[1] }),
                'C' => {
                    const p1 = try self.point(base);
                    c2 = try self.point(base);
                    try shape.cubicTo(p1, c2.?, try self.point(base));
                },
                'S' => {
                    const p1 = reflected(last_c2, shape.at);
                    c2 = try self.point(base);
                    try shape.cubicTo(p1, c2.?, try self.point(base));
                },
                'Q' => {
                    q = try self.point(base);
                    try self.quadratic(shape, q.?, try self.point(base));
                },
                'T' => {
                    q = reflected(last_q, shape.at);
                    try self.quadratic(shape, q.?, try self.point(base));
                },
                'A' => {
                    const rx = try self.coordinate();
                    const ry = try self.coordinate();
                    const phi = try self.coordinate();
                    const large = self.numbers.flag() orelse return error.BadPathData;
                    const sweep = self.numbers.flag() orelse return error.BadPathData;
                    try shape.arcTo(rx, ry, phi, large, sweep, try self.point(base));
                },
                else => return error.BadPathData,
            }
            last_c2 = c2;
            last_q = q;
        }
    }

    fn quadratic(self: *PathData, shape: *Shape, control: [2]f64, to: [2]f64) !void {
        _ = self;
        const cubic = bezier.quadraticAsCubic(shape.at, control, to);
        try shape.cubicTo(cubic.c1, cubic.c2, to);
    }

    fn coordinate(self: *PathData) error{BadPathData}!f64 {
        return self.numbers.number() orelse error.BadPathData;
    }

    fn point(self: *PathData, base: [2]f64) error{BadPathData}![2]f64 {
        const x = try self.coordinate();
        const y = try self.coordinate();
        return .{ base[0] + x, base[1] + y };
    }
};

/// The control `last` reflected about `at`, or `at` when the command before made none.
fn reflected(last: ?[2]f64, at: [2]f64) [2]f64 {
    const c = last orelse return at;
    return .{ 2 * at[0] - c[0], 2 * at[1] - c[1] };
}
