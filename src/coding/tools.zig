const std = @import("std");

pub const Language = enum {
    zig,
    rust,
    go,
    typescript,
    unknown,
};

pub const Tool = enum {
    code_search,
    symbol_search,
    compile,
    test_all,
    test_single,
    lint,
    format,
    diagnostics,
    git_diff,
    git_status,
};

pub const CommandSpec = struct {
    executable: []const u8,
    args: []const []const u8,
};

pub fn compileCommand(language: Language) ?CommandSpec {
    return switch (language) {
        .zig => .{ .executable = "zig", .args = &.{ "build" } },
        .rust => .{ .executable = "cargo", .args = &.{ "check" } },
        .go => .{ .executable = "go", .args = &.{ "build", "./..." } },
        .typescript => .{ .executable = "npx", .args = &.{ "tsc", "--noEmit" } },
        .unknown => null,
    };
}

pub fn testCommand(language: Language) ?CommandSpec {
    return switch (language) {
        .zig => .{ .executable = "zig", .args = &.{ "build", "test", "--summary", "all" } },
        .rust => .{ .executable = "cargo", .args = &.{ "test" } },
        .go => .{ .executable = "go", .args = &.{ "test", "./..." } },
        .typescript => .{ .executable = "npm", .args = &.{ "test", "--", "--runInBand" } },
        .unknown => null,
    };
}

pub fn formatCommand(language: Language) ?CommandSpec {
    return switch (language) {
        .zig => .{ .executable = "zig", .args = &.{ "fmt", "." } },
        .rust => .{ .executable = "cargo", .args = &.{ "fmt", "--", "--check" } },
        .go => .{ .executable = "gofmt", .args = &.{ "-w", "." } },
        .typescript => null,
        .unknown => null,
    };
}

pub fn isMutation(tool: Tool) bool {
    return switch (tool) {
        .format => true,
        else => false,
    };
}

test "Zig coding adapter uses repository-native build and test commands" {
    const compile = compileCommand(.zig).?;
    try std.testing.expectEqualStrings("zig", compile.executable);
    try std.testing.expectEqualStrings("build", compile.args[0]);

    const tests = testCommand(.zig).?;
    try std.testing.expectEqualStrings("test", tests.args[1]);
}
