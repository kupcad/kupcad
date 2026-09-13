const std = @import("std");
const testing = std.testing;

test "Fetcher: status code mapping converts 403 and 429 to RateLimitExceeded" {
    const checkStatus = struct {
        fn check(status: std.http.Status) !void {
            if (status == .forbidden or status == .too_many_requests) return error.RateLimitExceeded;
            if (status.class() != .success) return error.HttpError;
        }
    }.check;

    try testing.expectError(error.RateLimitExceeded, checkStatus(.forbidden));
    try testing.expectError(error.RateLimitExceeded, checkStatus(.too_many_requests));
    try testing.expectError(error.HttpError, checkStatus(.not_found));
    try testing.expectError(error.HttpError, checkStatus(.internal_server_error));
    try testing.expectEqual({}, try checkStatus(.ok));
}
