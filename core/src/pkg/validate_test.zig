const std = @import("std");
const testing = std.testing;
const validate = @import("validate.zig");
const limits = @import("limits.zig");
const ParsedPackage = @import("providers/provider.zig").ParsedPackage;

// Audit fix (SSRF): refs and hosts were interpolated into request URLs unchecked.
test "Validate: refs and hosts that could become request URLs are rejected" {
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("host.example/u/r@http://127.0.0.1:8080/x"));
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@../../x"));
    try testing.expectError(error.InvalidHost, ParsedPackage.parse("127.0.0.1:8080/u/r"));
}

// Audit fix: a downloaded package could pull deps from local files or internal hosts.
test "Validate: transitive deps may only reference public git hosts" {
    const allowed = [_][]const u8{ "codeberg.org/u/r", "github.com/u/r", "gitlab.com/u/r@v1" };
    for (allowed) |spec| try testing.expect((try ParsedPackage.parse(spec)).isAllowedTransitive());

    const forbidden = [_][]const u8{
        "127.0.0.1/u/r", "localhost/u/r", "2130706433/u/r", "file:/etc/passwd", "https://evil.example/p.tar.gz",
    };
    for (forbidden) |spec| {
        testing.expect(!(try ParsedPackage.parse(spec)).isAllowedTransitive()) catch |err| {
            std.debug.print("transitive spec allowed: {s}\n", .{spec});
            return err;
        };
    }
}

// Audit fix (path traversal): aliases become symlink names under .kupcad/pkg/.
test "Validate: validateAlias restricts dependency aliases to a safe charset" {
    const max_alias: [limits.MAX_ALIAS_LEN]u8 = @splat('x');
    const too_long: [limits.MAX_ALIAS_LEN + 1]u8 = @splat('x');

    const valid = [_][]const u8{ "good_name-1.0", "a", &max_alias };
    for (valid) |alias| try validate.validateAlias(alias);

    const invalid = [_][]const u8{ "", "../../etc", "..", ".store", "-flag", "a/b", "a\\b", "a\"b", "a b", &too_long };
    for (invalid) |alias| {
        testing.expectError(error.InvalidAlias, validate.validateAlias(alias)) catch |err| {
            std.debug.print("accepted alias: \"{f}\"\n", .{std.zig.fmtString(alias)});
            return err;
        };
    }
}
