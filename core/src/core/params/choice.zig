//! Checks a script parameter's value against its declared `choices` list (error.NotInChoices
//! unless it equals one). Used by `stdlib/params.zig`.

const value = @import("../value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn validate(vm: *VM, val: value.Value, choices: *value.ObjArray) !void {
    for (choices.items.items) |choice| {
        if (vm.valuesEqual(val, choice)) return; // Valid exact match found
    }
    return error.NotInChoices;
}
