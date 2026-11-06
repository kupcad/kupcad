//! Naming (docs/architecture.md §8): every face, edge and vertex carries a `Tag` into this
//! table, a row saying which operation made it from what. A split copies the tag, a merge
//! takes the union (a new row naming both), so a host's "the same face" survives a
//! rebuild. An operation also logs its changes (entities added, removed, split from what)
//! for a host mapping selections across a rebuild: the "bulletin board" (S p.262). Tags
//! are stable; indices are not (`Body.compact` renumbers).

const std = @import("std");
const types = @import("types.zig");
const Tag = types.Tag;

pub const Error = error{ OutOfMemory, TooMany };

/// What made an entity: the operation's number (the host's, opaque to Locus) and the
/// source: a host-given name, a parent tag (a split), or two parents (a merge).
pub const Row = struct {
    op: u32,
    source: Source,

    pub const Source = union(enum) {
        /// Given by the host when the entity was built: its own identifier.
        named: u32,
        /// Split from the entity with this tag.
        split: Tag,
        /// Merged from these two.
        merged: [2]Tag,
        /// Made from the entities with these two tags (a boolean's section edge from two
        /// faces).
        pair: [2]Tag,
    };
};

pub const Table = struct {
    rows: std.ArrayList(Row) = .empty,

    pub const empty: Table = .{};

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const Table, allocator: std.mem.Allocator) Error!Table {
        var out: Table = .empty;
        errdefer out.deinit(allocator);
        try out.rows.appendSlice(allocator, self.rows.items);
        return out;
    }

    /// A new tag with `row`. Tag 0 is reserved for "untagged".
    pub fn add(self: *Table, allocator: std.mem.Allocator, entry: Row) Error!Tag {
        if (self.rows.items.len + 1 >= std.math.maxInt(u32)) return error.TooMany;
        try self.rows.append(allocator, entry);
        return Tag.of(self.rows.items.len);
    }

    /// The tag a host names: `op` and its own `name`.
    pub fn named(self: *Table, allocator: std.mem.Allocator, op: u32, name: u32) Error!Tag {
        return self.add(allocator, .{ .op = op, .source = .{ .named = name } });
    }

    /// The tag of a piece split from `parent` by `op`: an untagged parent gives an
    /// untagged piece.
    pub fn split(self: *Table, allocator: std.mem.Allocator, op: u32, parent: Tag) Error!Tag {
        if (parent == .untagged) return .untagged;
        return self.add(allocator, .{ .op = op, .source = .{ .split = parent } });
    }

    /// The tag of the entity `op` merged from `a` and `b`: the one that is tagged when
    /// only one is, a new row naming both when both are.
    pub fn merged(self: *Table, allocator: std.mem.Allocator, op: u32, a: Tag, b: Tag) Error!Tag {
        if (a == .untagged) return b;
        if (b == .untagged) return a;
        if (a == b) return a;
        return self.add(allocator, .{ .op = op, .source = .{ .merged = .{ a, b } } });
    }

    /// The tag of an entity `op` made from the pair `a`, `b`.
    pub fn pair(self: *Table, allocator: std.mem.Allocator, op: u32, a: Tag, b: Tag) Error!Tag {
        return self.add(allocator, .{ .op = op, .source = .{ .pair = .{ a, b } } });
    }

    pub fn row(self: *const Table, tag: Tag) ?Row {
        if (tag == .untagged) return null;
        return self.rows.items[@backingInt(tag) - 1];
    }

    /// Whether `tag` descends from `ancestor` (or is it): follows splits and merges.
    pub fn descendsFrom(self: *const Table, tag: Tag, ancestor: Tag) bool {
        if (tag == .untagged or ancestor == .untagged) return false;
        if (tag == ancestor) return true;
        const r = self.row(tag) orelse return false;
        return switch (r.source) {
            .named => false,
            .split => |parent| self.descendsFrom(parent, ancestor),
            .merged, .pair => |parents| self.descendsFrom(parents[0], ancestor) or self.descendsFrom(parents[1], ancestor),
        };
    }

    /// The host's name at the root of `tag`, if it has one.
    pub fn nameOf(self: *const Table, tag: Tag) ?u32 {
        const r = self.row(tag) orelse return null;
        return switch (r.source) {
            .named => |n| n,
            .split => |parent| self.nameOf(parent),
            .merged, .pair => null,
        };
    }
};

/// One entry of an operation's change log.
pub const Change = struct {
    kind: types.EntityKind,
    what: What,
    /// The entity's tag after the operation (the removed one's before).
    tag: Tag,

    pub const What = enum(u8) { added, removed, split, merged };
};

/// What an operation did to the named entities, for a host mapping selections across a
/// rebuild.
pub const ChangeLog = struct {
    changes: std.ArrayList(Change) = .empty,

    pub const empty: ChangeLog = .{};

    pub fn deinit(self: *ChangeLog, allocator: std.mem.Allocator) void {
        self.changes.deinit(allocator);
        self.* = undefined;
    }

    pub fn record(self: *ChangeLog, allocator: std.mem.Allocator, change: Change) Error!void {
        if (change.tag == .untagged) return; // nothing a host could have named
        try self.changes.append(allocator, change);
    }
};
