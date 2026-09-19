const std = @import("std");

pub const GuardError = error{
    MissingExpectedHash,
    StaleSource,
};

/// Coding-mode mutations must be based on the same source state that was
/// inspected. Existing file_read_hashed/file_edit_hashed tools enforce this at
/// the filesystem boundary; this helper makes the invariant reusable by coding
/// orchestration and ACP.
pub fn requireFreshHash(expected: ?[]const u8, current: []const u8) GuardError!void {
    const value = expected orelse return error.MissingExpectedHash;
    if (!std.mem.eql(u8, value, current)) return error.StaleSource;
}

test "stale source is rejected before mutation" {
    try requireFreshHash("abc123", "abc123");
    try std.testing.expectError(error.StaleSource, requireFreshHash("abc123", "def456"));
    try std.testing.expectError(error.MissingExpectedHash, requireFreshHash(null, "def456"));
}
