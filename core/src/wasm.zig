const std = @import("std");
const api = @import("api.zig");

export fn alloc(len: usize) ?[*]u8 {
    // If allocation fails, returning `null` safely translates to `0` in WebAssembly
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

export fn format_code_wasm(source_ptr: [*]const u8, source_len: usize) [*]const u8 {
    const source = source_ptr[0..source_len];
    const allocator = std.heap.wasm_allocator;

    const formatted = api.formatCode(allocator, source, .{}) catch return source_ptr;

    // Using the stable ArrayListUnmanaged.empty
    var out = std.ArrayListUnmanaged(u8).empty;
    out.appendSlice(allocator, formatted) catch return source_ptr;
    out.append(allocator, 0) catch return source_ptr; // Null-terminate for JS

    return out.items.ptr;
}

export fn check_code_wasm(source_ptr: [*]const u8, source_len: usize) [*]const u8 {
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

    var out = std.ArrayListUnmanaged(u8).empty;

    // Manually serialize the LinterDiagnostics array to JSON
    out.append(allocator, '[') catch return "[]\x00".ptr;

    for (diags, 0..) |d, i| {
        if (i > 0) out.append(allocator, ',') catch return "[]\x00".ptr;

        const sev_str = switch (d.severity) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
        };

        // Pre-format the numbers into an isolated string
        const prefix = std.fmt.allocPrint(allocator,
            \\{{"line":{d},"col":{d},"offset":{d},"length":{d},"severity":"{s}","message":""
        , .{ d.loc.line, d.loc.col, d.loc.offset, d.loc.length, sev_str }) catch return "[]\x00".ptr;
        defer allocator.free(prefix);

        // Append the formatted string piece
        out.appendSlice(allocator, prefix) catch return "[]\x00".ptr;

        // Safely escape the message string
        for (d.message) |c| {
            switch (c) {
                '"' => out.appendSlice(allocator, "\\\"") catch return "[]\x00".ptr,
                '\\' => out.appendSlice(allocator, "\\\\") catch return "[]\x00".ptr,
                '\n' => out.appendSlice(allocator, "\\n") catch return "[]\x00".ptr,
                '\r' => out.appendSlice(allocator, "\\r") catch return "[]\x00".ptr,
                '\t' => out.appendSlice(allocator, "\\t") catch return "[]\x00".ptr,
                else => out.append(allocator, c) catch return "[]\x00".ptr,
            }
        }
        out.appendSlice(allocator, "\"}") catch return "[]\x00".ptr;
    }

    out.append(allocator, ']') catch return "[]\x00".ptr;
    out.append(allocator, 0) catch return "[]\x00".ptr; // Null-terminate for JS

    return out.items.ptr;
}
