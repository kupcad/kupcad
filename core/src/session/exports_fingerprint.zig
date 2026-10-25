//! What the modules importing a module can see of its run, hashed for the session's early
//! cutoff (ScriptSession.fingerprintOutput): each export's name and its value by content
//! (vm/value_hash.zig). A module that runs again and exports the same values stops the
//! re-evaluation there. A value whose content isn't hashed (a function, a class, an object)
//! counts as changed whenever its module runs again.

const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value_hash = @import("../vm/value_hash.zig");

/// The global the compiler keeps a script's exports in (compileExportStmt).
const EXPORTS_GLOBAL = "__exports__";

/// Hashes the exports of the script `vm` last ran into `hasher`; false when one of them
/// isn't hashed by content (what is hashed so far stays in).
pub fn hashExports(hasher: *std.hash.Wyhash, vm: *const VM) bool {
    const exports = vm.globals.get(EXPORTS_GLOBAL) orelse return true;
    if (!exports.isModule()) return false;
    const node_hashes = vm.dag_builder.node_hashes.items;
    const members = &exports.asModule().methods;
    for (members.keys(), members.values()) |name, v| {
        if (!value_hash.hashValue(hasher, node_hashes, name, value_hash.MAX_DEPTH)) return false;
        if (!value_hash.hashValue(hasher, node_hashes, v, value_hash.MAX_DEPTH)) return false;
    }
    return true;
}
