//! JSON-level secondwind request pipeline.
//!
//! The FFI rewrites provider JSON, but the host supplies independently verified
//! proof/coverage/token evidence. This module checks that every JSON field is
//! unchanged except content of existing role="tool" messages, then asks the
//! Context Gateway to admit or pass through the original request.

const std = @import("std");
const ffi = @import("secondwind_ffi.zig");
const gateway_mod = @import("context_gateway.zig");

pub const Evidence = struct {
    /// Must come from an independent proof/coverage verifier, not stats alone.
    lossless: bool,
    coverage_complete: bool,
    policy_allowed: bool,
    cache_compatible: bool,
    original_tokens: u32,
    candidate_tokens: u32,
};

pub const Result = struct {
    /// Allocator-owned JSON body; caller must free it.
    request_json: []u8,
    transformed: bool,
    stats_json: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.request_json);
        allocator.free(self.stats_json);
        self.* = undefined;
    }
};

/// Runs secondwind and returns either the admitted candidate or the byte-identical
/// original. Missing evidence, malformed envelopes, metadata changes, or failed
/// gateway checks never permit the candidate to cross the boundary.
pub fn rewriteForInference(
    allocator: std.mem.Allocator,
    session: *ffi.Session,
    gateway: anytype,
    intent_id: u128,
    original_json: []const u8,
    evidence: ?Evidence,
) !Result {
    const proof = evidence orelse return .{
        .request_json = try allocator.dupe(u8, original_json),
        .transformed = false,
        .stats_json = try allocator.dupe(u8, "{}"),
    };

    const envelope_json = try session.rewriteJson(allocator, original_json);
    defer allocator.free(envelope_json);

    var envelope_parsed = std.json.parseFromSlice(std.json.Value, allocator, envelope_json, .{}) catch
        return passthrough(allocator, original_json);
    defer envelope_parsed.deinit();

    if (envelope_parsed.value != .object) return passthrough(allocator, original_json);
    const rewritten_value = envelope_parsed.value.object.get("request") orelse
        return passthrough(allocator, original_json);
    const stats_value = envelope_parsed.value.object.get("stats") orelse
        return passthrough(allocator, original_json);

    // The upstream ABI returns {"kind":"error",...} on failure. Such an envelope
    // is not a request/stats result and is rejected above.
    if (stats_value != .object) return passthrough(allocator, original_json);
    const saved = stats_value.object.get("tokens_saved") orelse return passthrough(allocator, original_json);
    if (saved != .integer or saved.integer <= 0) return passthrough(allocator, original_json);

    const candidate_json = try std.json.Stringify.valueAlloc(allocator, rewritten_value, .{});
    defer allocator.free(candidate_json);

    if (!try onlyToolOutputContentChanged(allocator, original_json, candidate_json)) {
        return passthrough(allocator, original_json);
    }

    const validation = gateway_mod.Validation{
        .lossless = proof.lossless,
        .coverage_complete = proof.coverage_complete,
        .policy_allowed = proof.policy_allowed,
        .cache_compatible = proof.cache_compatible,
        .original_tokens = proof.original_tokens,
        .candidate_tokens = proof.candidate_tokens,
    };
    const admission = try gateway.beforeInference(intent_id, original_json, candidate_json, validation);
    const accepted = admission.decision == .transformed;
    return .{
        .request_json = try allocator.dupe(u8, if (accepted) candidate_json else original_json),
        .transformed = accepted,
        .stats_json = try std.json.Stringify.valueAlloc(allocator, stats_value, .{}),
    };
}

fn passthrough(allocator: std.mem.Allocator, original_json: []const u8) !Result {
    return .{
        .request_json = try allocator.dupe(u8, original_json),
        .transformed = false,
        .stats_json = try allocator.dupe(u8, "{}"),
    };
}

/// Compares the entire request after restoring original tool-result content into
/// the candidate. If anything else differs, the candidate is not eligible.
fn onlyToolOutputContentChanged(
    allocator: std.mem.Allocator,
    original_json: []const u8,
    candidate_json: []const u8,
) !bool {
    var original_parsed = std.json.parseFromSlice(std.json.Value, allocator, original_json, .{}) catch return false;
    defer original_parsed.deinit();
    var candidate_parsed = std.json.parseFromSlice(std.json.Value, allocator, candidate_json, .{}) catch return false;
    defer candidate_parsed.deinit();

    if (original_parsed.value != .object or candidate_parsed.value != .object) return false;
    const original_messages = original_parsed.value.object.get("messages") orelse return false;
    const candidate_messages_ptr = candidate_parsed.value.object.getPtr("messages") orelse return false;
    if (original_messages != .array or candidate_messages_ptr.* != .array) return false;
    if (original_messages.array.items.len != candidate_messages_ptr.array.items.len) return false;

    for (original_messages.array.items, candidate_messages_ptr.array.items) |before, *after| {
        if (before != .object or after.* != .object) return false;
        const before_role = before.object.get("role") orelse return false;
        const after_role = after.object.get("role") orelse return false;
        if (before_role != .string or after_role != .string) return false;
        if (!std.mem.eql(u8, before_role.string, after_role.string)) return false;

        const before_content = before.object.get("content") orelse return false;
        const after_content_ptr = after.object.getPtr("content") orelse return false;
        if (std.mem.eql(u8, before_role.string, "tool")) {
            // Only plain text tool output is eligible; multimodal/structured content
            // is never rewritten by this adapter.
            if (before_content != .string or after_content_ptr.* != .string) return false;
            after_content_ptr.* = before_content;
        } else if (!jsonValuesEqual(before_content, after_content_ptr.*)) {
            return false;
        }
    }

    const normalized_original = try std.json.Stringify.valueAlloc(allocator, original_parsed.value, .{});
    defer allocator.free(normalized_original);
    const normalized_candidate = try std.json.Stringify.valueAlloc(allocator, candidate_parsed.value, .{});
    defer allocator.free(normalized_candidate);
    return std.mem.eql(u8, normalized_original, normalized_candidate);
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    const left = std.json.Stringify.valueAlloc(std.heap.page_allocator, a, .{}) catch return false;
    defer std.heap.page_allocator.free(left);
    const right = std.json.Stringify.valueAlloc(std.heap.page_allocator, b, .{}) catch return false;
    defer std.heap.page_allocator.free(right);
    return std.mem.eql(u8, left, right);
}

test "request pipeline preserves original when proof evidence is absent" {
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
    var session = ffi.Session{ .api = api, .handle = null };
    var gateway = gateway_mod.Gateway(4){};
    const original = "{\"model\":\"m\",\"messages\":[{\"role\":\"tool\",\"content\":\"long\"}]}";
    const result = try rewriteForInference(std.testing.allocator, &session, &gateway, 1, original, null);
    defer {
        var owned = result;
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expect(!result.transformed);
    try std.testing.expectEqualStrings(original, result.request_json);
}

test "request diff permits only tool result content changes" {
    const allocator = std.testing.allocator;
    const original = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"keep\"},{\"role\":\"tool\",\"content\":\"long\"}]}";
    const allowed = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"keep\"},{\"role\":\"tool\",\"content\":\"short\"}]}";
    const changed_user = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"changed\"},{\"role\":\"tool\",\"content\":\"short\"}]}";
    const changed_model = "{\"model\":\"other\",\"messages\":[{\"role\":\"user\",\"content\":\"keep\"},{\"role\":\"tool\",\"content\":\"short\"}]}";
    try std.testing.expect(try onlyToolOutputContentChanged(allocator, original, allowed));
    try std.testing.expect(!try onlyToolOutputContentChanged(allocator, original, changed_user));
    try std.testing.expect(!try onlyToolOutputContentChanged(allocator, original, changed_model));
}
