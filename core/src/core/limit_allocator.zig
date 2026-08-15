const std = @import("std");

pub const LimitAllocator = struct {
    parent_allocator: std.mem.Allocator,
    bytes_allocated: usize = 0,
    max_bytes: usize,

    pub fn init(parent_allocator: std.mem.Allocator, max_bytes: usize) LimitAllocator {
        return .{
            .parent_allocator = parent_allocator,
            .max_bytes = max_bytes,
        };
    }

    pub fn allocator(self: *LimitAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        var self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (self.bytes_allocated + len > self.max_bytes) return null; // Sandboxed

        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) self.bytes_allocated += len;
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        var self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            if (self.bytes_allocated + diff > self.max_bytes) return false;
            if (self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
                self.bytes_allocated += diff;
                return true;
            }
            return false;
        } else {
            const diff = buf.len - new_len;
            if (self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
                self.bytes_allocated -= diff;
                return true;
            }
            return false;
        }
    }

    // Handle memory remapping with the sandbox limit
    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        var self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            if (self.bytes_allocated + diff > self.max_bytes) return null; // Sandboxed

            const result = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
            if (result != null) self.bytes_allocated += diff;
            return result;
        } else {
            const diff = buf.len - new_len;
            const result = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
            if (result != null) self.bytes_allocated -= diff;
            return result;
        }
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        var self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
        self.bytes_allocated -= buf.len;
    }
};
