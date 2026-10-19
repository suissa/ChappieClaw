//! Thin, opt-in binding to secondwind's versioned C ABI.
//!
//! This module deliberately accepts an injected symbol table instead of linking
//! secondwind by default. The host is responsible for loading the matching native
//! library and passing its exported functions. No transformation is enabled unless
//! an application explicitly creates a Session and calls rewriteJson.
//!
//! Pinned contract: secondwind C ABI v1 (workspace/package version 0.3.2).
//! JSON payloads are UTF-8. Buffers returned by the ABI belong to secondwind and
//! must be released exactly once with sw_free(pointer, length).

const std = @import("std");

pub const expected_abi_version: u32 = 1;
pub const max_response_bytes: usize = 16 * 1024 * 1024;

pub const Api = struct {
    abiVersion: *const fn () callconv(.c) u32,
    compress: *const fn ([*]const u8, usize, *usize) callconv(.c) ?[*]u8,
    verify: *const fn ([*]const u8, usize, *usize) callconv(.c) ?[*]u8,
    sessionNew: *const fn ([*]const u8, usize) callconv(.c) ?*anyopaque,
    sessionFree: *const fn (?*anyopaque) callconv(.c) void,
    rewrite: *const fn (?*anyopaque, [*]const u8, usize, *usize) callconv(.c) ?[*]u8,
    free: *const fn (?[*]u8, usize) callconv(.c) void,

    pub fn validate(self: Api) !void {
        if (self.abiVersion() != expected_abi_version) return error.SecondwindAbiVersionMismatch;
    }

    /// Calls sw_compress with a caller-encoded UTF-8 JSON payload and returns
    /// an allocator-owned copy of the UTF-8 JSON result.
    pub fn compressJson(self: Api, allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
        try self.validate();
        var output_len: usize = 0;
        const output = self.compress(input_json.ptr, input_json.len, &output_len) orelse
            return error.SecondwindNullOutput;
        return copyOwned(self, allocator, output, output_len);
    }

    /// Calls sw_verify. The caller must encode {"wire":"...","hash":"..."}
    /// as JSON and must inspect the returned {"ok":bool} value.
    pub fn verifyJson(self: Api, allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
        try self.validate();
        var output_len: usize = 0;
        const output = self.verify(input_json.ptr, input_json.len, &output_len) orelse
            return error.SecondwindNullOutput;
        return copyOwned(self, allocator, output, output_len);
    }

    fn copyOwned(
        self: Api,
        allocator: std.mem.Allocator,
        output: [*]u8,
        output_len: usize,
    ) ![]u8 {
        // Always release the library allocation, including over-limit responses.
        defer self.free(output, output_len);
        if (output_len > max_response_bytes) return error.SecondwindResponseTooLarge;
        return try allocator.dupe(u8, output[0..output_len]);
    }
};

pub const Session = struct {
    api: Api,
    handle: ?*anyopaque,

    /// Config is the ABI's UTF-8 JSON object. An empty object selects secondwind's
    /// documented defaults. No session is created implicitly.
    pub fn init(api: Api, config_json: []const u8) !Session {
        try api.validate();
        const handle = api.sessionNew(config_json.ptr, config_json.len) orelse
            return error.SecondwindSessionCreationFailed;
        return .{ .api = api, .handle = handle };
    }

    pub fn deinit(self: *Session) void {
        if (self.handle) |handle| {
            self.api.sessionFree(handle);
            self.handle = null;
        }
    }

    /// Rewrites a complete serialized provider request using sw_rewrite.
    /// Returns an allocator-owned copy of the ABI's JSON result:
    /// {"request":<rewritten request>,"stats":{...}} or {"kind":"error",...}.
    /// This transport wrapper does not itself establish Context Gateway evidence.
    pub fn rewriteJson(
        self: *Session,
        allocator: std.mem.Allocator,
        request_json: []const u8,
    ) ![]u8 {
        try self.api.validate();
        const handle = self.handle orelse return error.SecondwindSessionClosed;
        var output_len: usize = 0;
        const output = self.api.rewrite(handle, request_json.ptr, request_json.len, &output_len) orelse
            return error.SecondwindNullOutput;
        return self.api.copyOwned(allocator, output, output_len);
    }
};

test "rejects an ABI version mismatch before using the library" {
    const fake = Api{
        .abiVersion = testWrongAbiVersion,
        .compress = testCompress,
        .verify = testVerify,
        .sessionNew = testSessionNew,
        .sessionFree = testSessionFree,
        .rewrite = testRewrite,
        .free = testFree,
    };
    try std.testing.expectError(error.SecondwindAbiVersionMismatch, fake.validate());
}

fn testWrongAbiVersion() callconv(.c) u32 {
    return expected_abi_version + 1;
}
fn testCompress(_: [*]const u8, _: usize, _: *usize) callconv(.c) ?[*]u8 {
    return null;
}
fn testVerify(_: [*]const u8, _: usize, _: *usize) callconv(.c) ?[*]u8 {
    return null;
}
fn testSessionNew(_: [*]const u8, _: usize) callconv(.c) ?*anyopaque {
    return null;
}
fn testSessionFree(_: ?*anyopaque) callconv(.c) void {}
fn testRewrite(_: ?*anyopaque, _: [*]const u8, _: usize, _: *usize) callconv(.c) ?[*]u8 {
    return null;
}
fn testFree(_: ?[*]u8, _: usize) callconv(.c) void {}
