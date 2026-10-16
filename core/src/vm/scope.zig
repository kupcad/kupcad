//! `HandleScope`: keeps values a native function pushes on the VM stack rooted for the GC
//! until the scope ends, then restores the stack top.

const VM = @import("vm.zig").VM;

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
};
