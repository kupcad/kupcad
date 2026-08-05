const std = @import("std");
const api = @import("api.zig");

pub export fn alloc(len: usize) ?[*]u8 {
    // If allocation fails, returning `null` safely translates to `0` in WebAssembly
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

pub export fn free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

pub export fn format_code_wasm(source_ptr: [*]const u8, source_len: usize) [*]const u8 {
    const source = source_ptr[0..source_len];
    const allocator = std.heap.wasm_allocator;

    // Return a guaranteed null-terminated string on error
    const formatted = api.formatCode(allocator, source, .{}) catch return "Error: Syntax Error\x00".ptr;

    // Clean up the original slice once we are done copying it!
    defer allocator.free(formatted);

    var out = std.ArrayListUnmanaged(u8).empty;
    out.appendSlice(allocator, formatted) catch return "Error: Out of Memory\x00".ptr;
    out.append(allocator, 0) catch return "Error: Out of Memory\x00".ptr; // Null-terminate for JS

    return out.items.ptr;
}

pub export fn check_code_wasm(source_ptr: [*]const u8, source_len: usize) [*]const u8 {
    const source = source_ptr[0..source_len];
    const allocator = std.heap.wasm_allocator;

    // Run the linter
    const diags = api.checkCode(allocator, source, .{}) catch {
        return "[]\x00".ptr;
    };
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);

    out.writer.writeAll("[") catch return "[]\x00".ptr;
    for (diags, 0..) |d, i| {
        if (i > 0) out.writer.writeAll(",") catch return "[]\x00".ptr;

        // Map the diagnostic to an anonymous struct to flatten the hierarchy
        const flat_diag = .{
            .line = d.loc.line,
            .col = d.loc.col,
            .offset = d.loc.offset,
            .length = d.loc.length,
            .severity = d.severity.toString(), // Centralized string conversion
            .message = d.message,
        };

        // Leverage standard writer with std.json.fmt
        out.writer.print("{}", .{std.json.fmt(flat_diag, .{})}) catch return "[]\x00".ptr;
    }
    out.writer.writeAll("]") catch return "[]\x00".ptr;
    out.writer.writeAll("\x00") catch return "[]\x00".ptr; // Null-terminate for JS

    return out.written().ptr;
}
