//! `HandleScope`: keeps values a native function pushes on the VM stack rooted for the GC
//! until the scope ends, then restores the stack top; `array` and `map` make a new one
//! rooted so.

const VM = @import("vm.zig").VM;
const value = @import("../core/value.zig");

pub const HandleScope = struct {
    vm: *VM,
    saved_top: usize,

    /// Captures the current stack top
    pub fn init(vm: *VM) HandleScope {
        return .{
            .vm = vm,
            .saved_top = vm.stack_top,
        };
    }

    /// Restores the stack, automatically un-rooting all temporary variables
    pub fn deinit(self: HandleScope) void {
        self.vm.stack_top = self.saved_top;
    }

    /// A new empty Array, rooted until the scope ends.
    pub fn array(self: HandleScope) !*value.ObjArray {
        const arr = try self.vm.gc.allocateArray(self.vm);
        self.vm.push(value.Value.initObj(&arr.obj));
        return arr;
    }

    /// A new empty Map, rooted until the scope ends.
    pub fn map(self: HandleScope) !*value.ObjMap {
        const m = try self.vm.gc.allocateMap(self.vm);
        self.vm.push(value.Value.initObj(&m.obj));
        return m;
    }
};
