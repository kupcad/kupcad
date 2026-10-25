//! A value hashed by its content, for the fingerprints that tell whether a run's result
//! changed: what a module exports (session/exports_fingerprint.zig) and the model a script
//! builds (api.zig's modelFingerprint, which `kupcad check --fix` compares). A shape is
//! hashed by its node's hash in the geometry graph, which covers everything below it. A
//! value whose content isn't hashed (a function, a class, an object) makes `hashValue`
//! false: what it does depends on more than it holds.

const std = @import("std");
const value = @import("../core/value.zig");
const CONCRETE_NODE_SENTINEL = @import("dag.zig").CONCRETE_NODE_SENTINEL;

/// Containers nested deeper than this count as unhashed (one that holds itself would be
/// hashed forever).
pub const MAX_DEPTH = 64;

/// What each hashed value starts with, so a String and a Symbol of one name, or an empty
/// Array and an empty Map, hash apart.
const Kind = enum(u8) { nil, false, true, number, string, symbol, shape, sketch, array, map, json_object, bounding_box, range, font, path, assembly };

/// Hashes `v` into `hasher`; false when it, or a value inside it, isn't hashed by content
/// (what is hashed so far stays in). `node_hashes`: the geometry graph's, by node; `depth`:
/// how many containers deep it may go (MAX_DEPTH).
pub fn hashValue(hasher: *std.hash.Wyhash, node_hashes: []const u64, v: value.Value, depth: usize) bool {
    if (v.isNil()) return tag(hasher, .nil);
    if (v.isBool()) return tag(hasher, if (v.asBool()) .true else .false);
    if (v.isNumber()) {
        _ = tag(hasher, .number);
        hasher.update(std.mem.asBytes(&v.asNumber()));
        return true;
    }
    if (!v.isObject() or depth == 0) return false;
    switch (v.asObj().obj_type) {
        .string => return chars(hasher, .string, v.asString().chars),
        .symbol => return chars(hasher, .symbol, v.asSymbol().chars),
        .geometry => return node(hasher, .shape, node_hashes, v.asGeometry().dag_idx),
        .cross_section => return node(hasher, .sketch, node_hashes, v.asCrossSection().dag_idx),
        .path => {
            const p = v.asPath();
            _ = tag(hasher, .path);
            hasher.update(std.mem.asBytes(&p.start));
            hasher.update(std.mem.sliceAsBytes(p.segments));
            return true;
        },
        .array => return sequence(hasher, .array, node_hashes, v.asArray().items.items, depth),
        // Its name, which an export writes, then its parts
        .assembly => {
            const assembly = v.asAssembly();
            _ = chars(hasher, .assembly, assembly.name.chars);
            return sequence(hasher, .array, node_hashes, assembly.parts.items.items, depth);
        },
        .map => return entries(hasher, .map, node_hashes, &v.asMap().map, depth),
        .json_object => return entries(hasher, .json_object, node_hashes, &v.asJsonObject().map, depth),
        .bbox => {
            const box = v.asBBox();
            _ = tag(hasher, .bounding_box);
            hasher.update(std.mem.asBytes(&box.min));
            hasher.update(std.mem.asBytes(&box.max));
            return true;
        },
        .range => {
            const r = v.asRange();
            _ = tag(hasher, .range);
            hasher.update(std.mem.asBytes(&[_]f64{ r.start, r.end, r.step }));
            hasher.update(&.{@intFromBool(r.is_exclusive)});
            return true;
        },
        // Its file's bytes, and its name, which may be the file's
        .font => {
            const font = v.asFont();
            _ = chars(hasher, .font, font.bytes);
            return chars(hasher, .string, font.name.chars);
        },
        else => return false,
    }
}

fn tag(hasher: *std.hash.Wyhash, kind: Kind) bool {
    hasher.update(&.{@backingInt(kind)});
    return true;
}

fn chars(hasher: *std.hash.Wyhash, kind: Kind, text: []const u8) bool {
    _ = tag(hasher, kind);
    hasher.update(std.mem.asBytes(&text.len));
    hasher.update(text);
    return true;
}

/// A shape or a sketch by its node's hash, which is its content's; one with no node (a
/// mesh made outside the graph) isn't hashed.
fn node(hasher: *std.hash.Wyhash, kind: Kind, node_hashes: []const u64, index: u32) bool {
    if (index == CONCRETE_NODE_SENTINEL or index >= node_hashes.len) return false;
    _ = tag(hasher, kind);
    hasher.update(std.mem.asBytes(&node_hashes[index]));
    return true;
}

fn sequence(hasher: *std.hash.Wyhash, kind: Kind, node_hashes: []const u64, items: []const value.Value, depth: usize) bool {
    _ = tag(hasher, kind);
    hasher.update(std.mem.asBytes(&items.len));
    for (items) |item| if (!hashValue(hasher, node_hashes, item, depth - 1)) return false;
    return true;
}

fn entries(hasher: *std.hash.Wyhash, kind: Kind, node_hashes: []const u64, map: *const value.ValueMap, depth: usize) bool {
    _ = tag(hasher, kind);
    hasher.update(std.mem.asBytes(&map.count()));
    for (map.keys(), map.values()) |k, item| {
        if (!hashValue(hasher, node_hashes, k, depth - 1)) return false;
        if (!hashValue(hasher, node_hashes, item, depth - 1)) return false;
    }
    return true;
}
