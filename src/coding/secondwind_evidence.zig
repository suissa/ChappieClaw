//! Independent per-tool-output proof producer for secondwind inline rewrites.
//!
//! Stats returned by sw_rewrite are informational only. This verifier independently
//! recompresses the original block, requires the candidate to match the exact inline
//! wire, and asks sw_verify to validate the portable certificate. Offloads, verbatim
//! results, mismatches, malformed JSON, and FFI errors are rejected fail-closed.

const std = @import("std");
const ffi = @import("secondwind_ffi.zig");

pub const Proof = struct {
    verified: bool = false,
    original_tokens: u32 = 0,
    candidate_tokens: u32 = 0,
};

const CompressionInput = struct {
    block: []const u8,
    model: []const u8,
};

const VerifyInput = struct {
    wire: []const u8,
    hash: []const u8,
};

/// Verifies one original/candidate tool-output pair without trusting sw_rewrite stats.
/// This deliberately supports inline compression only; offload markers require a
/// separate store-recovery proof and are never admitted by this helper.
pub fn verifyInlineBlock(
    allocator: std.mem.Allocator,
    api: ffi.Api,
    original: []const u8,
    candidate: []const u8,
    model: []const u8,
) Proof {
    const input_json = std.json.Stringify.valueAlloc(allocator, CompressionInput{
        .block = original,
        .model = model,
    }, .{}) catch return .{};
    defer allocator.free(input_json);

    const compressed_json = api.compressJson(allocator, input_json) catch return .{};
    defer allocator.free(compressed_json);

    var compressed = std.json.parseFromSlice(std.json.Value, allocator, compressed_json, .{}) catch return .{};
    defer compressed.deinit();
    if (compressed.value != .object) return .{};

    const kind = stringField(compressed.value, "kind") orelse return .{};
    if (!std.mem.eql(u8, kind, "compressed")) return .{};

    const wire = stringField(compressed.value, "wire") orelse return .{};
    if (!std.mem.eql(u8, wire, candidate)) return .{};

    const certificate = compressed.value.object.get("certificate") orelse return .{};
    if (certificate != .object) return .{};
    const hash = stringField(certificate, "hash") orelse return .{};

    const input_tokens = integerField(compressed.value, "input_tokens") orelse return .{};
    const output_tokens = integerField(compressed.value, "output_tokens") orelse return .{};
    if (input_tokens <= 0 or output_tokens < 0 or output_tokens >= input_tokens) return .{};

    const verify_json = std.json.Stringify.valueAlloc(allocator, VerifyInput{
        .wire = candidate,
        .hash = hash,
    }, .{}) catch return .{};
    defer allocator.free(verify_json);

    const verdict_json = api.verifyJson(allocator, verify_json) catch return .{};
    defer allocator.free(verdict_json);
    var verdict = std.json.parseFromSlice(std.json.Value, allocator, verdict_json, .{}) catch return .{};
    defer verdict.deinit();
    if (verdict.value != .object) return .{};
    const ok = verdict.value.object.get("ok") orelse return .{};
    if (ok != .bool or !ok.bool) return .{};

    const original_count: u32 = std.math.cast(u32, input_tokens) orelse return .{};
    const candidate_count: u32 = std.math.cast(u32, output_tokens) orelse return .{};
    return .{
        .verified = true,
        .original_tokens = original_count,
        .candidate_tokens = candidate_count,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn integerField(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .integer) field.integer else null;
}

test "evidence producer rejects unavailable FFI operations" {
    const Fake = struct {
        fn abi() callconv(.c) u32 { return ffi.expected_abi_version; }
        fn nullBytes(_: [*]const u8, _: usize, _: *usize) callconv(.c) ?[*]u8 { return null; }
        fn nullSession(_: [*]const u8, _: usize) callconv(.c) ?*anyopaque { return null; }
        fn noSession(_: ?*anyopaque) callconv(.c) void {}
        fn nullRewrite(_: ?*anyopaque, _: [*]const u8, _: usize, _: *usize) callconv(.c) ?[*]u8 { return null; }
        fn noFree(_: ?[*]u8, _: usize) callconv(.c) void {}
    };
    const api = ffi.Api{
        .abiVersion = Fake.abi,
        .compress = Fake.nullBytes,
        .verify = Fake.nullBytes,
        .sessionNew = Fake.nullSession,
        .sessionFree = Fake.noSession,
        .rewrite = Fake.nullRewrite,
        .free = Fake.noFree,
    };
    const proof = verifyInlineBlock(std.testing.allocator, api, "original", "candidate", "model");
    try std.testing.expect(!proof.verified);
    try std.testing.expectEqual(@as(u32, 0), proof.original_tokens);
    try std.testing.expectEqual(@as(u32, 0), proof.candidate_tokens);
}
