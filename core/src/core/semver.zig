const std = @import("std");

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,

    /// Parses a standard semver string (e.g. "1.2.3" or "v1.2")
    pub fn parse(str: []const u8) !Version {
        var clean_str = str;
        if (std.mem.startsWith(u8, clean_str, "v")) {
            clean_str = clean_str[1..];
        }

        var it = std.mem.splitScalar(u8, clean_str, '.');
        const major_str = it.next() orelse return error.InvalidSemVer;
        const minor_str = it.next() orelse "0";
        const patch_str = it.next() orelse "0";

        return Version{
            .major = try std.fmt.parseInt(u64, major_str, 10),
            .minor = try std.fmt.parseInt(u64, minor_str, 10),
            .patch = try std.fmt.parseInt(u64, patch_str, 10),
        };
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
