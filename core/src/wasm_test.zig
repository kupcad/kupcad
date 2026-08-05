const std = @import("std");
const testing = std.testing;

// Import the WASM module functions directly
const wasm = @import("wasm.zig");

test "WASM Interop: format_code_wasm handles invalid and empty inputs gracefully" {
    // Test Syntax Error Handling
    const bad_src = "class 123 { invalid }";
    const res_bad = wasm.format_code_wasm(bad_src.ptr, bad_src.len);

    // std.mem.sliceTo safely reads a generic [*]const u8 until it hits the 0 byte
    const bad_slice = std.mem.sliceTo(res_bad, 0);
    try testing.expectEqualStrings("Error: Syntax Error", bad_slice);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.format_code_wasm(empty_src.ptr, empty_src.len);

    const empty_slice = std.mem.sliceTo(res_empty, 0);
    // Depending on Formatter behavior, an empty file usually formats to an empty string
    // but the critical assertion is that it did not panic!
    try testing.expect(empty_slice.len == 0 or std.mem.eql(u8, empty_slice, "Error: Syntax Error"));
}

test "WASM Interop: check_code_wasm returns valid empty JSON on syntax errors" {
    // Test Syntax Error Handling
    const bad_src = "def !invalid";
    const res_bad = wasm.check_code_wasm(bad_src.ptr, bad_src.len);

    const bad_slice = std.mem.sliceTo(res_bad, 0);

    // Even if the parser fails catastrophically, we must return a valid JSON array
    // to prevent the JS Web Worker from crashing when calling JSON.parse()
    try testing.expectEqualStrings("[]", bad_slice);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.check_code_wasm(empty_src.ptr, empty_src.len);

    const empty_slice = std.mem.sliceTo(res_empty, 0);
    // An empty file has no diagnostics, so it should return an empty JSON array
    try testing.expectEqualStrings("[]", empty_slice);
}
