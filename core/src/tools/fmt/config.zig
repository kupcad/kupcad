pub const Config = struct {
    indent_width: u8 = 2,
    /// Longest line a construct is kept on: a call, list or chain that won't fit is laid
    /// out over lines (one the author broke is kept broken whatever its length).
    line_width: usize = 100,
    sort_imports: bool = true,
};
