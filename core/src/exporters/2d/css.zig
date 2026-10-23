//! The CSS of an SVG's `<style>` elements, as far as a drawing reads it (svg_read.zig): rules
//! of simple selectors (a type, classes and an id on one element, `*`, and lists of them),
//! each property's value for an element by the cascade (the matching rule of the highest
//! specificity, the last of those). What a drawing has no use for is left out: rules of
//! other selectors (descendants, children, siblings, attributes, pseudo-classes) and
//! at-rules (`@media`, `@font-face`). `declared` reads a list of declarations, a rule's or
//! a `style` attribute's.

const std = @import("std");

/// How much an id, a class and a type weigh in a selector's specificity.
const ID_WEIGHT = 10_000;
const CLASS_WEIGHT = 100;
const TYPE_WEIGHT = 1;
/// What marks a value as important, which the cascade here weighs no differently.
const IMPORTANT = "!important";

/// The element a value is asked for: its tag's name, its id and its `class` attribute.
pub const Element = struct { name: []const u8, id: ?[]const u8, classes: []const u8 };

/// The value of the property `name` in `declarations` (`fill: none; stroke: red`), the
/// last if it is given twice.
pub fn declared(declarations: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var all = std.mem.splitScalar(u8, declarations, ';');
    while (all.next()) |declaration| {
        const colon = std.mem.findScalar(u8, declaration, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace), name)) continue;
        const v = std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace);
        found = std.mem.trimEnd(u8, if (std.mem.endsWith(u8, v, IMPORTANT)) v[0 .. v.len - IMPORTANT.len] else v, &std.ascii.whitespace);
    }
    return found;
}

/// A simple selector of a rule: what it asks of an element, and its declarations.
const Selector = struct {
    type: ?[]const u8,
    id: ?[]const u8,
    classes: []const []const u8,
    declarations: []const u8,
    specificity: u32,
};

/// The style sheet: every rule's selectors in the order the file gives them, indexed by
/// the one thing each asks first (its id, else its first class, else its type).
pub const Sheet = struct {
    selectors: std.ArrayList(Selector) = .empty,
    by_id: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    by_class: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    by_type: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    universal: std.ArrayList(u32) = .empty,

    /// The rules of the CSS `text` (a `<style>`'s), added after those before; all the
    /// sheet holds is `arena`'s.
    pub fn add(self: *Sheet, arena: std.mem.Allocator, text: []const u8) !void {
        const css = try withoutComments(arena, text);
        var pos: usize = 0;
        while (true) {
            while (pos < css.len and std.ascii.isWhitespace(css[pos])) pos += 1;
            if (pos >= css.len) return;
            if (css[pos] == '@') {
                pos = pastAtRule(css, pos);
                continue;
            }
            const open = std.mem.findScalarPos(u8, css, pos, '{') orelse return;
            const close = std.mem.findScalarPos(u8, css, open, '}') orelse css.len;
            var selectors = std.mem.splitScalar(u8, css[pos..open], ',');
            while (selectors.next()) |text_of| try self.addSelector(arena, std.mem.trim(u8, text_of, &std.ascii.whitespace), css[open + 1 .. close]);
            pos = close + 1;
        }
    }

    /// The value of the property `name` the sheet gives `element`: the matching rule's of
    /// the highest specificity that declares it, the last of those; null when none does.
    pub fn value(self: *const Sheet, element: Element, name: []const u8) ?[]const u8 {
        var best: ?Best = null;
        // The selectors that may match: those under its id, each class, its type, and `*`
        if (element.id) |id| self.consider(self.by_id.get(id), element, name, &best);
        var classes = std.mem.tokenizeAny(u8, element.classes, &std.ascii.whitespace);
        while (classes.next()) |class| self.consider(self.by_class.get(class), element, name, &best);
        self.consider(self.by_type.get(element.name), element, name, &best);
        self.consider(self.universal, element, name, &best);
        return if (best) |b| b.value else null;
    }

    /// The value the cascade has chosen so far, and the selector's weight and place.
    const Best = struct { specificity: u32, order: u32, value: []const u8 };

    fn consider(self: *const Sheet, candidates: ?std.ArrayList(u32), element: Element, name: []const u8, best: *?Best) void {
        for ((candidates orelse return).items) |i| {
            const s = self.selectors.items[i];
            if (!matches(s, element)) continue;
            const v = declared(s.declarations, name) orelse continue;
            if (best.*) |b| if (s.specificity < b.specificity or (s.specificity == b.specificity and i < b.order)) continue;
            best.* = .{ .specificity = s.specificity, .order = i, .value = v };
        }
    }

    /// The selector `text`, with `declarations`, unless it is one the sheet leaves out.
    fn addSelector(self: *Sheet, arena: std.mem.Allocator, text: []const u8, declarations: []const u8) !void {
        if (text.len == 0) return;
        // A combinator, an attribute or a pseudo-class: not an element's own
        if (std.mem.findAny(u8, text, " \t\r\n>+~[:(") != null) return;
        var classes: std.ArrayList([]const u8) = .empty;
        var id: ?[]const u8 = null;
        const type_end = std.mem.findAny(u8, text, ".#") orelse text.len;
        const type_name: ?[]const u8 = if (type_end == 0 or std.mem.eql(u8, text[0..type_end], "*")) null else text[0..type_end];
        var rest = text[type_end..];
        while (rest.len > 0) {
            const next = std.mem.findAnyPos(u8, rest, 1, ".#") orelse rest.len;
            const part = rest[1..next];
            if (part.len == 0) return;
            if (rest[0] == '.') try classes.append(arena, part) else if (id == null) id = part else return;
            rest = rest[next..];
        }
        const specificity: u32 = (if (id != null) @as(u32, ID_WEIGHT) else 0) + @as(u32, @intCast(classes.items.len)) * CLASS_WEIGHT + (if (type_name != null) @as(u32, TYPE_WEIGHT) else 0);
        const index: u32 = @intCast(self.selectors.items.len);
        try self.selectors.append(arena, .{ .type = type_name, .id = id, .classes = classes.items, .declarations = declarations, .specificity = specificity });
        const list = if (id) |key| try entry(arena, &self.by_id, key) else if (classes.items.len > 0) try entry(arena, &self.by_class, classes.items[0]) else if (type_name) |key| try entry(arena, &self.by_type, key) else &self.universal;
        try list.append(arena, index);
    }
};

fn entry(arena: std.mem.Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList(u32)), key: []const u8) !*std.ArrayList(u32) {
    const found = try map.getOrPut(arena, key);
    if (!found.found_existing) found.value_ptr.* = .empty;
    return found.value_ptr;
}

/// Whether `element` is what `s` asks for: its type, its id and every class.
fn matches(s: Selector, element: Element) bool {
    if (s.type) |t| if (!std.mem.eql(u8, t, element.name)) return false;
    if (s.id) |id| if (element.id == null or !std.mem.eql(u8, id, element.id.?)) return false;
    for (s.classes) |class| {
        var classes = std.mem.tokenizeAny(u8, element.classes, &std.ascii.whitespace);
        while (classes.next()) |c| {
            if (std.mem.eql(u8, c, class)) break;
        } else return false;
    }
    return true;
}

/// `text` without its comments (`/* ... */`) and CDATA's markers, in `arena`.
fn withoutComments(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const next = std.mem.findAnyPos(u8, text, pos, "/<]") orelse text.len;
        try out.appendSlice(arena, text[pos..next]);
        pos = next;
        if (pos >= text.len) break;
        const rest = text[pos..];
        if (std.mem.startsWith(u8, rest, "/*")) {
            pos = if (std.mem.findPos(u8, text, pos + 2, "*/")) |end| end + 2 else text.len;
        } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            pos += "<![CDATA[".len;
        } else if (std.mem.startsWith(u8, rest, "]]>")) {
            pos += "]]>".len;
        } else {
            try out.append(arena, text[pos]);
            pos += 1;
        }
    }
    return out.items;
}

/// Where what follows the at-rule starting at `pos` starts: past its `;`, or past its
/// block, braces within it counted.
fn pastAtRule(css: []const u8, pos: usize) usize {
    var depth: usize = 0;
    var i = pos;
    while (i < css.len) : (i += 1) switch (css[i]) {
        ';' => if (depth == 0) return i + 1,
        '{' => depth += 1,
        '}' => {
            if (depth <= 1) return i + 1;
            depth -= 1;
        },
        else => {},
    };
    return css.len;
}
