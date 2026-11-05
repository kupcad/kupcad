//! A value hashed by its content, for the fingerprints that tell whether a run's result
//! changed: what a module exports (session/exports_fingerprint.zig) and the model a script
//! builds (api.zig's modelFingerprint, which `kupcad check --fix` compares). A shape is
//! hashed by its node's hash in the geometry graph, which covers everything below it. A
//! value whose content isn't hashed (a function, a class, an object) makes `hashValue`
//! false: what it does depends on more than it holds.

const std = @import("std");
const value = @import("../core/value.zig");
const CONCRETE_NODE_SENTINEL = @import("dag.zig").CONCRETE_NODE_SENTINEL;

/// Containers nested deeper than this count as unhashed.
const MAX_DEPTH = 64;

/// What each hashed value starts with, so a String and a Symbol of one name, or an empty
/// Array and an empty Map, hash apart. `seen`: a container met before, by when it was.
const Kind = enum(u8) { nil, false, true, number, string, symbol, shape, sketch, array, map, json_object, bounding_box, range, font, path, assembly, seen };

/// Hashes `v` into `hasher`; false when it, or a value inside it, isn't hashed by content
/// (what is hashed so far stays in), or there was no room to hash it. `node_hashes`: the
/// geometry graph's, by node. Each container is hashed once: met again (a structure that
/// shares its parts, or holds itself), it is hashed by when it was met first. Hashed whole
/// each time, `x = [x, x]` forty times over took 2^40 steps after every run.
pub fn hashValue(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, node_hashes: []const u64, v: value.Value) bool {
    var hashing: Hashing = .{ .allocator = allocator, .hasher = hasher, .node_hashes = node_hashes };
    defer hashing.seen.deinit(allocator);
    return hashing.hash(v, MAX_DEPTH);
}

const Hashing = struct {
    allocator: std.mem.Allocator,
    hasher: *std.hash.Wyhash,
    node_hashes: []const u64,
    /// The containers hashed so far, each with when it was met first.
    seen: std.AutoHashMapUnmanaged(*const value.Obj, u32) = .empty,

    fn hash(self: *Hashing, v: value.Value, depth: usize) bool {
        if (v.isNil()) return self.tag(.nil);
        if (v.isBool()) return self.tag(if (v.asBool()) .true else .false);
        if (v.isNumber()) {
            _ = self.tag(.number);
            self.hasher.update(std.mem.asBytes(&v.asNumber()));
            return true;
        }
        if (!v.isObject() or depth == 0) return false;
        switch (v.asObj().obj_type) {
            .string => return self.chars(.string, v.asString().chars),
            .symbol => return self.chars(.symbol, v.asSymbol().chars),
            .geometry => return self.node(.shape, v.asGeometry().dag_idx),
            .cross_section => return self.node(.sketch, v.asCrossSection().dag_idx),
            .path => {
                const p = v.asPath();
                _ = self.tag(.path);
                self.hasher.update(std.mem.asBytes(&p.start));
                self.hasher.update(std.mem.sliceAsBytes(p.segments));
                return true;
            },
            .bbox => {
                const box = v.asBBox();
                _ = self.tag(.bounding_box);
                self.hasher.update(std.mem.asBytes(&box.min));
                self.hasher.update(std.mem.asBytes(&box.max));
                return true;
            },
            .range => {
                const r = v.asRange();
                _ = self.tag(.range);
                self.hasher.update(std.mem.asBytes(&[_]f64{ r.start, r.end, r.step }));
                self.hasher.update(&.{@intFromBool(r.is_exclusive)});
                return true;
            },
            // Its file's bytes, and its name, which may be the file's
            .font => {
                const font = v.asFont();
                _ = self.chars(.font, font.bytes);
                return self.chars(.string, font.name.chars);
            },
            .array, .assembly, .map, .json_object => {},
            else => return false,
        }

        const met = self.seen.getOrPut(self.allocator, v.asObj()) catch return false;
        if (met.found_existing) {
            _ = self.tag(.seen);
            self.hasher.update(std.mem.asBytes(met.value_ptr));
            return true;
        }
        met.value_ptr.* = @intCast(self.seen.count() - 1);
        switch (v.asObj().obj_type) {
            .array => return self.sequence(.array, v.asArray().items.items, depth),
            // Its name, which an export writes, then its parts
            .assembly => {
                const assembly = v.asAssembly();
                _ = self.chars(.assembly, assembly.name.chars);
                return self.sequence(.array, assembly.parts.items.items, depth);
            },
            .map => return self.entries(.map, .of(v), depth),
            .json_object => return self.entries(.json_object, .of(v), depth),
            else => unreachable,
        }
    }

    fn tag(self: *Hashing, kind: Kind) bool {
        self.hasher.update(&.{@backingInt(kind)});
        return true;
    }

    fn chars(self: *Hashing, kind: Kind, text: []const u8) bool {
        _ = self.tag(kind);
        self.hasher.update(std.mem.asBytes(&text.len));
        self.hasher.update(text);
        return true;
    }

    /// A shape or a sketch by its node's hash, which is its content's; one with no node (a
    /// mesh made outside the graph) isn't hashed.
    fn node(self: *Hashing, kind: Kind, index: u32) bool {
        if (index == CONCRETE_NODE_SENTINEL or index >= self.node_hashes.len) return false;
        _ = self.tag(kind);
        self.hasher.update(std.mem.asBytes(&self.node_hashes[index]));
        return true;
    }

    fn sequence(self: *Hashing, kind: Kind, items: []const value.Value, depth: usize) bool {
        _ = self.tag(kind);
        self.hasher.update(std.mem.asBytes(&items.len));
        for (items) |item| if (!self.hash(item, depth - 1)) return false;
        return true;
    }

    fn entries(self: *Hashing, kind: Kind, held: value.Entries, depth: usize) bool {
        _ = self.tag(kind);
        self.hasher.update(std.mem.asBytes(&held.count));
        var it = held;
        while (it.next()) |entry| {
            if (!self.hash(entry.key, depth - 1)) return false;
            if (!self.hash(entry.value, depth - 1)) return false;
        }
        return true;
    }
};
