//! What a built-in takes: the runtime parses its keywords from it, and tools that read a
//! call before it runs (`kupcad check`, the editor's parameter hints) read the same lists.

pub const Signature = struct {
    /// Positional parameters, in order.
    positional: []const []const u8 = &.{},
    /// Every keyword it accepts, in the order its errors list them.
    keywords: []const []const u8 = &.{},
    /// Parameters, by position or keyword, that must be greater than zero.
    sizes: []const []const u8 = &.{},
    /// What a lone positional argument means when it sets more than the first parameter
    /// (`cube(5)` is a 5 mm cube, not one 5 mm in x): the name hints show for it.
    single: ?[]const u8 = null,
};
