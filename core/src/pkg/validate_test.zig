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
        "gitea:127.0.0.1/u/r", "gitea:localhost/u/r", "gitlab:2130706433/u/r", "file:/etc/passwd", "https://evil.example/p.tar.gz",
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

test "Validate: a self-hosted git server says which API it speaks" {
    // Unknown hosts used to be taken for Gitea, so a self-hosted GitLab got Gitea API calls.
    try testing.expectError(error.UnknownPackageHost, ParsedPackage.parse("git.example.com/team/parts"));
    try testing.expectEqual(.gitlab, (try ParsedPackage.parse("gitlab:git.example.com/team/parts@v1")).provider);
    try testing.expectEqual(.gitea, (try ParsedPackage.parse("gitea:git.example.com/team/parts")).provider);
    try testing.expectEqual(.gitea, (try ParsedPackage.parse("codeberg.org/team/parts")).provider);
    // A prefix that contradicts a known host is a mistake, not an override.
    try testing.expectError(error.ProviderMismatch, ParsedPackage.parse("gitea:github.com/team/parts"));
    try testing.expectEqual(.github, (try ParsedPackage.parse("github.com/team/parts")).provider);

    // The prefixed and the bare form of one package are the same package.
    const a = try (try ParsedPackage.parse("gitlab:gitlab.com/team/parts")).pkgId(testing.allocator);
    defer testing.allocator.free(a);
    const b = try (try ParsedPackage.parse("gitlab.com/team/parts")).pkgId(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "pkgId: tells apart packages whose names run together, and one repository at two refs" {
    // `github.com/a-b/c` and `github.com/a/b-c` were both `github.com-a-b-c`, and a
    // repository at two refs was one package.
    const specs = [_][]const u8{ "github.com/a-b/c", "github.com/a/b-c", "github.com/a/b-c@v2", "github.com/a/b-c@main" };
    var ids: [specs.len][]const u8 = undefined;
    for (specs, &ids) |spec, *id| id.* = try (try ParsedPackage.parse(spec)).pkgId(testing.allocator);
    defer for (ids) |id| testing.allocator.free(id);
    for (ids[0..3], 0..) |id, i| {
        for (ids[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier, id));
    }
    // The default ref spelled out is the same package, and the id still reads as the location.
    try testing.expectEqualStrings(ids[1], ids[3]);
    try testing.expect(std.mem.startsWith(u8, ids[0], "github.com-a-b-c-"));
    try testing.expect(std.mem.startsWith(u8, ids[1], "github.com-a-b-c-"));
}

test "ParsedPackage: a .zip URL is refused, with a reason" {
    // It was accepted and then extracted as a gzip'd tarball.
    const provider_mod = @import("providers/provider.zig");
    try testing.expectError(error.UnsupportedArchive, ParsedPackage.parse("https://example.com/parts.zip"));
    try testing.expectEqualStrings("only .tar.gz archives can be installed, not .zip", provider_mod.describeParseError(error.UnsupportedArchive));
    try testing.expectEqual(.http, (try ParsedPackage.parse("https://example.com/parts.tar.gz")).provider);
}
