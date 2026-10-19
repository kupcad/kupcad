//! The methods of `Font`, a font file a script imported (`import label from
//! "./Inter-Bold.ttf"`, which stdlib/files.zig's import_font reads) for `text(font:)`:
//! `name`, the font's own. `puts` and interpolation print that name, `inspect` `#<Font name>`
//! (core/value.zig). Bound by `core_classes.zig`.

const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

/// Font#name -> its full name, as the font file gives it (`"Inter Bold"`), or the file's name
/// for a font that gives none.
fn fontName(_: *VM, font: *value.ObjFont) value.Value {
    return value.Value.initObj(&font.name.obj);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "name", .func = common.wrapMethod(fontName) },
};
