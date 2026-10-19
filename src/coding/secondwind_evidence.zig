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


/// Request-level evidence derived by checking every changed tool-output block.
/// Policy permission and cache compatibility remain explicit host decisions; this
/// function never infers them from a successful compression or its statistics.
pub const RequestEvidence = struct {
    lossless: bool,
    coverage_complete: bool,
    policy_allowed: bool,
    cache_compatible: bool,
    original_tokens: u32,
    candidate_tokens: u32,
};

pub fn verifyRequestCoverage(
    allocator: std.mem.Allocator,
    api: ffi.Api,
    original_json: []const u8,
    candidate_json: []const u8,
    model: []const u8,
    policy_allowed: bool,
    cache_compatible: bool,
) ?RequestEvidence {
    var original = std.json.parseFromSlice(std.json.Value, allocator, original_json, .{}) catch return null;
    defer original.deinit();
    var candidate = std.json.parseFromSlice(std.json.Value, allocator, candidate_json, .{}) catch return null;
    defer candidate.deinit();
    if (original.value != .object or candidate.value != .object) return null;

    const original_messages = original.value.object.get("messages") orelse return null;
    const candidate_messages_ptr = candidate.value.object.getPtr("messages") orelse return null;
    if (original_messages != .array or candidate_messages_ptr.* != .array) return null;
    if (original_messages.array.items.len != candidate_messages_ptr.array.items.len) return null;

    var changed_blocks: usize = 0;
    var original_tokens: u32 = 0;
    var candidate_tokens: u32 = 0;

    for (original_messages.array.items, candidate_messages_ptr.array.items) |before, *after| {
        if (before != .object or after.* != .object) return null;
        const before_role = before.object.get("role") orelse return null;
        const after_role = after.object.get("role") orelse return null;
        if (before_role != .string or after_role != .string) return null;
        if (!std.mem.eql(u8, before_role.string, after_role.string)) return null;

        const before_content = before.object.get("content") orelse return null;
        const after_content_ptr = after.object.getPtr("content") orelse return null;
        if (std.mem.eql(u8, before_role.string, "tool")) {
            if (before_content != .string or after_content_ptr.* != .string) return null;
            if (!std.mem.eql(u8, before_content.string, after_content_ptr.string)) {
                const proof = verifyInlineBlock(
                    allocator,
                    api,
                    before_content.string,
                    after_content_ptr.string,
                    model,
                );
                if (!proof.verified) return null;
                original_tokens = std.math.add(u32, original_tokens, proof.original_tokens) catch return null;
                candidate_tokens = std.math.add(u32, candidate_tokens, proof.candidate_tokens) catch return null;
                changed_blocks += 1;
                // Restore only for the structural comparison below; the parsed candidate
                // remains private to this verifier and is not returned to the caller.
                after_content_ptr.* = before_content;
            }
        }
    }

    // After restoring every eligible tool content, the entire request must be equal.
    // This catches changed model/settings, message metadata, tool calls, and non-tool text.
    const normalized_original = std.json.Stringify.valueAlloc(allocator, original.value, .{}) catch return null;
    defer allocator.free(normalized_original);
    const normalized_candidate = std.json.Stringify.valueAlloc(allocator, candidate.value, .{}) catch return null;
    defer allocator.free(normalized_candidate);
    if (!std.mem.eql(u8, normalized_original, normalized_candidate)) return null;
    if (changed_blocks == 0 or candidate_tokens >= original_tokens) return null;

    return .{
        .lossless = true,
        .coverage_complete = true,
        .policy_allowed = policy_allowed,
        .cache_compatible = cache_compatible,
        .original_tokens = original_tokens,
        .candidate_tokens = candidate_tokens,
    };
}

test "request coverage rejects changed user content and metadata" {
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
    const original = "{\\"model\\":\\"m\\",\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"keep\\"},{\\"role\\":\\"tool\\",\\"content\\":\\"long\\"}]}";
    const changed_user = "{\\"model\\":\\"m\\",\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"changed\\"},{\\"role\\":\\"tool\\",\\"content\\":\\"short\\"}]}";
    try std.testing.expect(verifyRequestCoverage(std.testing.allocator, api, original, changed_user, "m", true, true) == null);
}
