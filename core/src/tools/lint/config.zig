//! Lint settings, the "lint" section of `.kupcad.json`: each rule by its id, at the level
//! it reports at (`"lint": { "unused-variable": "off", "self-subtraction": "error" }`).

pub const Level = enum {
    off,
    info,
    warning,
    @"error",
};

/// One field per rule, named by its id (Linter checks the two lists match).
pub const Config = struct {
    @"nonpositive-size": Level = .warning,
    @"unused-variable": Level = .warning,
    @"unreachable-code": Level = .warning,
    @"self-subtraction": Level = .warning,
    @"param-order": Level = .warning,
};
