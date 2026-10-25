//! Semantic versions for the package manager: `Version` parses and compares "1.2.3", and
//! `Constraint` parses "^1.2", "~1.2", ">=2.0" or an exact version and tells whether a
//! version satisfies it.

const std = @import("std");

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,

    /// Parses a version as a tag names one ("1.2.3", "v1.2"): one to three parts of plain
    /// digits, a part left out 0. A fourth part, a sign, a `_` (which parseInt takes) or a
    /// pre-release suffix is no version: `1.2.3.4` was taken for 1.2.3.
    pub fn parse(str: []const u8) !Version {
        const clean_str = if (std.mem.startsWith(u8, str, "v")) str[1..] else str;
        var parts: [3]u64 = @splat(0);
        var it = std.mem.splitScalar(u8, clean_str, '.');
        var count: usize = 0;
        while (it.next()) |part| : (count += 1) {
            if (count == parts.len or part.len == 0) return error.InvalidSemVer;
            for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidSemVer;
            parts[count] = try std.fmt.parseInt(u64, part, 10);
        }
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn compare(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

pub const ConstraintOp = enum { exact, caret, tilde, greater_equal };

pub const Constraint = struct {
    op: ConstraintOp,
    version: Version,

    /// Parses constraints like "^1.2.3", "~1.2", ">=2.0.0"
    pub fn parse(str: []const u8) !Constraint {
        if (str.len == 0) return error.InvalidConstraint;
        var op: ConstraintOp = .exact;
        var ver_str = str;

        if (std.mem.startsWith(u8, str, "^")) {
            op = .caret;
            ver_str = str[1..];
        } else if (std.mem.startsWith(u8, str, "~")) {
            op = .tilde;
            ver_str = str[1..];
        } else if (std.mem.startsWith(u8, str, ">=")) {
            op = .greater_equal;
            ver_str = str[2..];
        } else if (std.mem.startsWith(u8, str, "=")) {
            op = .exact;
            ver_str = str[1..];
        }

        const ver = try Version.parse(ver_str);
        return Constraint{ .op = op, .version = ver };
    }

    /// Evaluates if a given target version satisfies this constraint
    pub fn satisfies(self: Constraint, target: Version) bool {
        switch (self.op) {
            .exact => return self.version.compare(target) == .eq,
            .greater_equal => return self.version.compare(target) != .gt,
            .caret => {
                // Caret (^): Allows changes that do not modify the left-most non-zero digit
                if (self.version.compare(target) == .gt) return false;
                if (self.version.major == 0) {
                    if (self.version.minor == 0) {
                        return target.major == 0 and target.minor == 0 and target.patch == self.version.patch;
                    }
                    return target.major == 0 and target.minor == self.version.minor;
                }
                return target.major == self.version.major;
            },
            .tilde => {
                // Tilde (~): Allows patch-level changes if minor is specified
                if (self.version.compare(target) == .gt) return false;
                return target.major == self.version.major and target.minor == self.version.minor;
            },
        }
    }
};
