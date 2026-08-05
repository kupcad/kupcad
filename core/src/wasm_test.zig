const std = @import("std");
const testing = std.testing;

// Import the WASM module functions directly
const wasm = @import("wasm.zig");

test "WASM Interop: format_code_wasm handles invalid and empty inputs gracefully" {
    // Test Syntax Error Handling
    const bad_src = "class 123 { invalid }";
    const res_bad = wasm.format_code_wasm(bad_src.ptr, bad_src.len);

    // Formatter should fail and return null
    try testing.expect(res_bad == null);

    // Retrieve and verify the last error message
    const err_ptr = wasm.get_last_error();
    const err_slice = std.mem.sliceTo(err_ptr, 0);
    try testing.expectEqualStrings("Syntax Error", err_slice);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.format_code_wasm(empty_src.ptr, empty_src.len);

    // Depending on the exact Formatter implementation, an empty file might
    // succeed with an empty string, or throw a Syntax Error. We handle both gracefully.
    if (res_empty) |ptr| {
        const empty_slice = std.mem.sliceTo(ptr, 0);
        try testing.expectEqualStrings("", empty_slice);
    } else {
        const err_ptr2 = wasm.get_last_error();
        const err_slice2 = std.mem.sliceTo(err_ptr2, 0);
        try testing.expectEqualStrings("Syntax Error", err_slice2);
    }
}

test "WASM Interop: check_code_wasm returns valid JSON on syntax errors" {
    // Test Syntax Error Handling
    const bad_src = "def !invalid";
    const res_bad = wasm.check_code_wasm(bad_src.ptr, bad_src.len);

    // The linter captures syntax errors natively and returns them as diagnostics!
    // Therefore, it should NOT return null, but a valid JSON array.
    try testing.expect(res_bad != null);

    const bad_slice = std.mem.sliceTo(res_bad.?, 0);

    // Verify it is a valid JSON array structure
    try testing.expect(bad_slice.len >= 2);
    try testing.expect(bad_slice[0] == '[');
    try testing.expect(bad_slice[bad_slice.len - 1] == ']');

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.check_code_wasm(empty_src.ptr, empty_src.len);

    try testing.expect(res_empty != null);
    const empty_slice = std.mem.sliceTo(res_empty.?, 0);

    // An empty file has no diagnostics, so it should return an empty JSON array
    try testing.expectEqualStrings("[]", empty_slice);
}
