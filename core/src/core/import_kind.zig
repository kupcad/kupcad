//! What an `import` reads: a KupCAD module, or a file a built-in reads as a value (an STL or
//! STEP mesh, JSON data, a font). The `type` its `with { }` gives says which (`import machine from
//! "./machine.dat" with { type: "json" }`); without one, the path's extension does (in any
//! case: `.STL` too), and any other path is a module. The compiler, the parser's checks, the
//! workspace and the watcher all ask here, so they agree on what an import is.

const std = @import("std");
const ast = @import("ast.zig");

/// The extensions that make an import a file's, without a `type`.
const EXTENSIONS = [_]struct { extension: []const u8, kind: Kind }{
    .{ .extension = ".stl", .kind = .stl },
    .{ .extension = ".step", .kind = .step },
    .{ .extension = ".stp", .kind = .step },
    .{ .extension = ".json", .kind = .json },
    .{ .extension = ".dxf", .kind = .dxf },
    .{ .extension = ".svg", .kind = .svg },
    .{ .extension = ".ttf", .kind = .font },
    .{ .extension = ".otf", .kind = .font },
};
/// The one key `with { }` takes.
const TYPE_KEY = "type";

/// Every type name, for an error that lists them: `"kup", "stl", "step" or "json"`.
pub const TYPE_NAMES = blk: {
    const kinds = std.enums.values(Kind);
    var text: []const u8 = "";
    for (kinds, 0..) |kind, i| {
        const separator = if (i == 0) "" else if (i + 1 == kinds.len) " or " else ", ";
        text = text ++ separator ++ "\"" ++ kind.typeName() ++ "\"";
    }
    break :blk text;
};

pub const Kind = enum {
    module,
    stl,
    step,
    json,
    font,
    dxf,
    svg,

    /// The built-in that reads a file of this kind, or null for a module, which the VM
    /// imports itself.
    pub fn importer(self: Kind) ?[]const u8 {
        return switch (self) {
            .module => null,
            .stl => "import_stl",
            .step => "import_step",
            .json => "import_json",
            .font => "import_font",
            .dxf => "import_dxf",
            .svg => "import_svg",
        };
    }

    /// The extension of a file of this kind, without the dot, for an example in an error:
    /// "ttf" for a font, whose type name isn't one. A module's is "kup".
    pub fn extension(self: Kind) []const u8 {
        for (EXTENSIONS) |entry| {
            if (entry.kind == self) return entry.extension[1..];
        }
        return self.typeName();
    }

    /// What `with { type: ... }` calls it.
    pub fn typeName(self: Kind) []const u8 {
        return switch (self) {
            .module => "kup",
            .stl => "stl",
            .step => "step",
            .json => "json",
            .font => "font",
            .dxf => "dxf",
            .svg => "svg",
        };
    }

    /// Braces name what it has (`import { a, b } from`): a module's exports, the keys of a
    /// JSON file's object. A mesh or a font has nothing to name.
    pub fn hasKeys(self: Kind) bool {
        return switch (self) {
            .module, .json => true,
            .stl, .step, .font, .dxf, .svg => false,
        };
    }

    pub fn fromTypeName(name: []const u8) ?Kind {
        for (std.enums.values(Kind)) |kind| {
            if (std.mem.eql(u8, kind.typeName(), name)) return kind;
        }
        return null;
    }
};

/// What the extension of `path` makes it.
pub fn ofPath(path: []const u8) Kind {
    for (EXTENSIONS) |entry| {
        if (std.ascii.endsWithIgnoreCase(path, entry.extension)) return entry.kind;
    }
    return .module;
}

/// What an import's (or a re-export's) `with { }` says, read from `attributes` (the hash
/// literal, or .none without one).
pub const Attributes = union(enum) {
    /// No `type`: the path's extension decides.
    none,
    kind: Kind,
    /// What is wrong with them, and the node it is about, for the parser to report.
    invalid: Invalid,

    pub const Invalid = struct {
        node: ast.NodeIndex,
        problem: Problem,
        /// The key or type name it is about (in the tree's strings); empty when it has none.
        name: []const u8 = "",
    };

    pub const Problem = enum {
        /// A key other than `type`.
        unknown_key,
        type_twice,
        /// A value that isn't a string or a symbol literal.
        not_a_name,
        /// A string or symbol that names no Kind.
        unknown_type,
    };
};

pub fn readAttributes(tree: *const ast.Tree, attributes: ast.NodeIndex) Attributes {
    const node = tree.getNode(attributes) orelse return .none;
    if (node.tag != .hash_literal) return .none;
    var found: Attributes = .none;
    for (tree.getHashEntries(tree.nodeSpan(node))) |entry| {
        const key = literalName(tree, entry.key);
        if (key == null or !std.mem.eql(u8, key.?, TYPE_KEY)) {
            return .{ .invalid = .{ .node = entry.key, .problem = .unknown_key, .name = key orelse "" } };
        }
        if (found != .none) return .{ .invalid = .{ .node = entry.key, .problem = .type_twice } };
        const name = literalName(tree, entry.value) orelse return .{ .invalid = .{ .node = entry.value, .problem = .not_a_name } };
        const kind = Kind.fromTypeName(name) orelse return .{ .invalid = .{ .node = entry.value, .problem = .unknown_type, .name = name } };
        found = .{ .kind = kind };
    }
    return found;
}

/// What `stmt` reads: its `type`, else what its path's extension makes it. Attributes the
/// parser refused count as none (a tree with errors is never compiled).
pub fn ofImport(tree: *const ast.Tree, stmt: ast.ImportStmt) Kind {
    return of(tree, stmt.path, stmt.attributes);
}

fn of(tree: *const ast.Tree, path: ast.StringId, attributes: ast.NodeIndex) Kind {
    return switch (readAttributes(tree, attributes)) {
        .kind => |kind| kind,
        .none, .invalid => ofPath(tree.getString(path)),
    };
}

/// A file a statement reads: an import's, or a re-export's (`export { a } from "./a.kup"`).
pub const Reference = struct {
    /// As written, before import_path resolves it against the importer.
    path: []const u8,
    kind: Kind,
};

/// What `node` reads, or null for a statement that reads nothing (an export of the file's own
/// names, anything but an import or an export).
pub fn referenceOf(tree: *const ast.Tree, node: *const ast.Node) ?Reference {
    const path: ast.StringId, const attributes: ast.NodeIndex = switch (node.tag) {
        .import_stmt => .{ tree.importStmt(node).path, tree.importStmt(node).attributes },
        .export_stmt => .{ tree.exportStmt(node).path, tree.exportStmt(node).attributes },
        else => return null,
    };
    if (path == .none) return null;
    return .{ .path = tree.getString(path), .kind = of(tree, path, attributes) };
}

/// The text of a string or symbol literal (`"json"`, `:json`, the `type:` of `type: x`),
/// or null for any other node.
fn literalName(tree: *const ast.Tree, index: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(index) orelse return null;
    return switch (node.tag) {
        .string, .symbol => tree.getString(@fromBackingInt(node.data)),
        else => null,
    };
}
