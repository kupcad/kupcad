//! The kerning of a font: how much closer (or further apart) two glyphs sit than their
//! advances alone place them, from the pair adjustments of the font's `kern` feature in its
//! GPOS table, or, for a font with none, from its older `kern` table, as OpenType asks. Text
//! is set one line, left to right, without shaping: each pair's adjustment is the first
//! glyph's advance change, which is what a `kern` feature gives. A pair's placement change
//! for the second glyph, which kerning doesn't use, lookups that skip marks between the two
//! glyphs, and the `kern` table's cross-stream, vertical and state-machine subtables aren't
//! applied.

const std = @import("std");
const tatfi = @import("tatfi");

const gpos = tatfi.tables.gpos;
const GlyphId = tatfi.GlyphId;

/// The OpenType feature that holds a font's kerning.
const KERN_FEATURE = tatfi.Tag.from_bytes("kern");

pub const Kerning = struct {
    table: ?tatfi.opentype_layout.LayoutTable(.gpos),
    /// The lookups of every `kern` feature, in the order the font applies them.
    lookups: []u16,
    /// The `kern` table, read only when GPOS gives no kerning.
    legacy: ?tatfi.tables.kern = null,

    /// The kerning of `face`: GPOS's, or its `kern` table's when GPOS has no `kern` feature.
    pub fn init(allocator: std.mem.Allocator, face: *const tatfi.Face) !Kerning {
        var kerning = try gposKerning(allocator, face);
        if (kerning.lookups.len == 0) kerning.legacy = face.tables.kern;
        return kerning;
    }

    fn gposKerning(allocator: std.mem.Allocator, face: *const tatfi.Face) !Kerning {
        const table = face.tables.opentype_layout.gpos orelse return .{ .table = null, .lookups = &.{} };
        var lookups: std.ArrayList(u16) = .empty;
        errdefer lookups.deinit(allocator);
        // A feature per script and language can name the same lookups: each is taken once
        var features = table.features.iterator();
        while (features.next()) |feature| {
            if (feature.tag.inner != KERN_FEATURE.inner) continue;
            var indices = feature.lookup_indices.iterator();
            while (indices.next()) |index| {
                if (std.mem.findScalar(u16, lookups.items, index) == null) try lookups.append(allocator, index);
            }
        }
        std.mem.sortUnstable(u16, lookups.items, {}, std.sort.asc(u16));
        return .{ .table = table, .lookups = try lookups.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Kerning, allocator: std.mem.Allocator) void {
        allocator.free(self.lookups);
    }

    /// The change to `left`'s advance when `right` follows it, in font units.
    pub fn between(self: *const Kerning, left: GlyphId, right: GlyphId) i32 {
        if (self.legacy) |kern| return legacyBetween(kern, left, right);
        const table = self.table orelse return 0;
        var total: i32 = 0;
        for (self.lookups) |index| {
            const lookup = table.lookups.get(index) orelse continue;
            var subtables = lookup.subtables.iterator();
            // A lookup's first subtable that has the pair gives it. An extension lookup's
            // subtables come unwrapped, so a font that puts its pairs in one (Roboto Serif)
            // is read as one that doesn't.
            while (subtables.next()) |subtable| {
                const adjustment = pairAdjustment(subtable, left, right) orelse continue;
                total += adjustment;
                break;
            }
        }
        return total;
    }
};

/// The `kern` table's adjustment for the pair: the sum of its horizontal subtables', each
/// giving the pair's value or none.
fn legacyBetween(kern: tatfi.tables.kern, left: GlyphId, right: GlyphId) i32 {
    var total: i32 = 0;
    var subtables = kern.subtables.iterator();
    while (subtables.next()) |subtable| {
        if (!subtable.horizontal or subtable.variable or subtable.has_cross_stream) continue;
        total += subtable.glyphs_kerning(left, right) orelse 0;
    }
    return total;
}

/// What `subtable` changes `left`'s advance by before `right`, or null when the pair isn't
/// its own: `left` isn't covered, or a glyph-pair subtable lists no such pair.
fn pairAdjustment(subtable: gpos.PositioningSubtable, left: GlyphId, right: GlyphId) ?i32 {
    const pairs = switch (subtable) {
        .pair => |p| p,
        else => return null,
    };
    const coverage_index = pairs.coverage().get(left) orelse return null;
    const first = switch (pairs) {
        .format1 => |f| first: {
            const set = f.sets.get(coverage_index) orelse return null;
            const records = set.get(right) catch return null;
            break :first records[0];
        },
        // Every covered first glyph has a class; class 0 holds the glyphs no class lists
        .format2 => |f| first: {
            const records = f.matrix.get(.{ f.classes[0].get(left), f.classes[1].get(right) }) orelse return null;
            break :first records[0];
        },
    };
    return first.x_advance;
}
