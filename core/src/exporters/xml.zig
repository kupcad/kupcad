//! The XML a drawing or a package holds (an SVG file, a 3MF model): its tags one by one
//! (`Scanner`), each with its attributes as written (`Tag`), past the text between them,
//! comments, CDATA, processing instructions and the DOCTYPE. An entity in a value isn't
//! decoded: what the readers take from values is numbers and names.

const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

/// One tag of a file: a start tag (with its attributes' text), an end tag, or one that
/// is both (`<path/>`).
pub const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool,
    self_closing: bool,
    /// Where its `<` is, and where what follows its `>` starts
    offset: usize,
    end: usize,

    /// The value of the attribute `name`, as written.
    pub fn attribute(self: Tag, name: []const u8) ?[]const u8 {
        var all = self.attributeList();
        while (all.next()) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// The value of the attribute whose name, past its namespace's prefix (`p:path`'s
    /// `path`), is `local`.
    pub fn prefixedAttribute(self: Tag, local: []const u8) ?[]const u8 {
        var all = self.attributeList();
        while (all.next()) |a| if (std.mem.eql(u8, localName(a.name), local) and a.name.len > local.len) return a.value;
        return null;
    }

    pub fn attributeList(self: Tag) Attributes {
        return .{ .rest = self.attributes };
    }
};

/// A name past its namespace's prefix: `path` of `p:path`, `vertex` of `vertex`.
pub fn localName(name: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, name, ':')) |colon| name[colon + 1 ..] else name;
}

/// A tag's attributes, one by one, as written.
pub const Attributes = struct {
    rest: []const u8,

    pub const Attribute = struct { name: []const u8, value: []const u8 };

    pub fn next(self: *Attributes) ?Attribute {
        const rest = std.mem.trimStart(u8, self.rest, &std.ascii.whitespace);
        const eq = std.mem.findScalar(u8, rest, '=') orelse return null;
        const name = std.mem.trim(u8, rest[0..eq], &std.ascii.whitespace);
        const quoted = std.mem.trimStart(u8, rest[eq + 1 ..], &std.ascii.whitespace);
        if (quoted.len == 0 or (quoted[0] != '"' and quoted[0] != '\'')) return null;
        const close = std.mem.findScalarPos(u8, quoted, 1, quoted[0]) orelse return null;
        self.rest = quoted[close + 1 ..];
        return .{ .name = name, .value = quoted[1..close] };
    }
};

pub const Scanner = struct {
    text: []const u8,
    pos: usize = 0,

    /// The next tag, past text, comments, CDATA, processing instructions and the DOCTYPE.
    pub fn next(self: *Scanner, diag: *Diagnostic) error{Unreadable}!?Tag {
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

    fn past(self: *Scanner, from: usize, end: []const u8, what: []const u8, diag: *Diagnostic) error{Unreadable}!usize {
        const at = std.mem.findPos(u8, self.text, from, end) orelse return diag.fail("line {d}: {s} doesn't end", .{ lineOf(self.text, from), what });
        return at + end.len;
    }

    fn tag(self: *Scanner, open: usize, diag: *Diagnostic) error{Unreadable}!Tag {
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
        return .{ .name = body[0..name_end], .attributes = body[name_end..], .closing = closing, .self_closing = self_closing, .offset = open, .end = i + 1 };
    }
};

/// The line of `text` that `offset` is on, from 1.
pub fn lineOf(text: []const u8, offset: usize) usize {
    return std.mem.countScalar(u8, text[0..offset], '\n') + 1;
}
