const std = @import("std");

/// The LineIndex provides O(log N) lookups for converting flat byte offsets
/// into Line/Column coordinates, and handles UTF-16 conversion for LSP clients.
pub const LineIndex = struct {
    line_starts: []const u32,
    source: []const u8,

    /// Scans the source text and records the byte offset of every new line.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts = std.ArrayListUnmanaged(u32).empty;
        errdefer starts.deinit(allocator);

        // Line 1 (index 0) always starts at offset 0
        try starts.append(allocator, 0);

        for (source, 0..) |c, i| {
            if (c == '\n') {
                try starts.append(allocator, @intCast(i + 1));
            }
        }

        return LineIndex{
            .line_starts = try starts.toOwnedSlice(allocator),
            .source = source,
        };
    }

    /// Finds the 0-indexed line number for a given byte offset using binary search.
    pub fn getLine(self: *const LineIndex, offset: u32) u32 {
        var left: usize = 0;
        var right: usize = self.line_starts.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.line_starts[mid] > offset) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }
        return @intCast(left - 1);
    }

    /// Returns the 0-indexed UTF-8 byte column.
    /// (Use this if the LSP client successfully negotiates "utf-8" PositionEncodingKind).
    pub fn getUtf8Column(self: *const LineIndex, offset: u32) u32 {
        const line = self.getLine(offset);
        const line_start = self.line_starts[line];
        return offset - line_start;
    }

    /// Returns the 0-indexed UTF-16 code unit column.
    /// (Use this if the LSP client falls back to the default "utf-16" encoding).
    pub fn getUtf16Column(self: *const LineIndex, offset: u32) u32 {
        const line = self.getLine(offset);
        const line_start = self.line_starts[line];

        // Slice the exact text from the start of the line up to the token offset
        const line_text_to_offset = self.source[line_start..offset];

        // Calculate how many UTF-16 code units this UTF-8 text represents
        return @intCast(std.unicode.calcUtf16LeLen(line_text_to_offset) catch {
            // Fallback to byte length if invalid unicode is encountered
            return offset - line_start;
        });
    }
};
