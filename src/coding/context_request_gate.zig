//! Typed pre-inference Context Gateway boundary.
//!
//! This is the seam between the agent's provider-neutral ChatRequest and an
//! external context transformer such as ChappieContextCondenser. The transformer
//! is deliberately not embedded here. A candidate request can replace the original
//! only when the supplied evidence proves losslessness, coverage, policy permission,
//! cache compatibility, and strict token/byte reduction.

const std = @import("std");
const providers = @import("../providers/root.zig");
const gateway_mod = @import("context_gateway.zig");

pub const Candidate = struct {
    request: providers.ChatRequest,
    original_tokens: u32,
    candidate_tokens: u32,
    lossless: bool,
    coverage_complete: bool,
    policy_allowed: bool,
    cache_compatible: bool,
};

pub const Admission = struct {
    request: providers.ChatRequest,
    transformed: bool,
};

/// Decide which typed request may cross the provider boundary.
///
/// The candidate is supplied by a separate transformer. This module only enforces
/// the runtime admission contract; it does not pretend that a model or transformer
/// assertion is cryptographic proof of semantic equivalence.
pub fn admit(
    gateway: anytype,
    request_id: u64,
    intent_id: u128,
    original: providers.ChatRequest,
    candidate: ?Candidate,
) !Admission {
    const c = candidate orelse return .{ .request = original, .transformed = false };
    const original_bytes = requestSize(original);
    const candidate_bytes = requestSize(c.request);

    const validation = gateway_mod.Validation{
        .lossless = c.lossless,
        .coverage_complete = c.coverage_complete,
        .policy_allowed = c.policy_allowed and requestMetadataCompatible(original, c.request),
        .cache_compatible = c.cache_compatible,
        .original_tokens = c.original_tokens,
        .candidate_tokens = c.candidate_tokens,
    };

    const original_marker = try fingerprintMarker(std.heap.page_allocator, original, original_bytes);
    defer std.heap.page_allocator.free(original_marker);
    const candidate_marker = try fingerprintMarker(std.heap.page_allocator, c.request, candidate_bytes);
    defer std.heap.page_allocator.free(candidate_marker);

    const admitted = try gateway.beforeInference(
        intent_id,
        original_marker,
        candidate_marker,
        validation,
    );

    _ = request_id;
    if (admitted.decision != .transformed) {
        return .{ .request = original, .transformed = false };
    }
    return .{ .request = c.request, .transformed = true };
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn toolsEqual(a: ?[]const providers.ToolSpec, b: ?[]const providers.ToolSpec) bool {
    if (a == null or b == null) return a == null and b == null;
    if (a.?.len != b.?.len) return false;
    for (a.?, b.?) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or
            !std.mem.eql(u8, left.description, right.description) or
            !std.mem.eql(u8, left.parameters_json, right.parameters_json))
        {
            return false;
        }
    }
    return true;
}

/// A context condenser may replace messages, but cannot silently change provider,
/// model, tools, budgets, cache/session scope, or generation behavior.
fn requestMetadataCompatible(original: providers.ChatRequest, candidate: providers.ChatRequest) bool {
    return std.mem.eql(u8, original.model, candidate.model) and
        optionalStringEqual(original.session_id, candidate.session_id) and
        @as(u64, @bitCast(original.temperature)) == @as(u64, @bitCast(candidate.temperature)) and
        original.max_tokens == candidate.max_tokens and
        original.timeout_secs == candidate.timeout_secs and
        optionalStringEqual(original.reasoning_effort, candidate.reasoning_effort) and
        original.include_reasoning == candidate.include_reasoning and
        toolsEqual(original.tools, candidate.tools);
}

fn fingerprintMarker(allocator: std.mem.Allocator, request: providers.ChatRequest, size: usize) ![]u8 {
    const marker = try allocator.alloc(u8, @max(@as(usize, 1), size));
    const hash = fingerprintRequest(request);
    const hash_bytes = std.mem.asBytes(&hash);
    for (marker, 0..) |*byte, index| byte.* = hash_bytes[index % hash_bytes.len];
    return marker;
}

fn fingerprintRequest(request: providers.ChatRequest) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    const mix = struct {
        fn bytes(value: []const u8, current: *u64) void {
            for (value) |byte| {
                current.* ^= byte;
                current.* *%= 0x100000001b3;
            }
        }
    }.bytes;
    mix(request.model, &hash);
    if (request.session_id) |id| mix(id, &hash);
    for (request.messages) |message| {
        hash ^= @intFromEnum(message.role);
        hash *%= 0x100000001b3;
        mix(message.content, &hash);
        if (message.name) |name| mix(name, &hash);
        if (message.tool_call_id) |id| mix(id, &hash);
        if (message.content_parts) |parts| {
            for (parts) |part| switch (part) {
                .text => |text| mix(text, &hash),
                .image_url => |image| mix(image.url, &hash),
                .image_base64 => |image| {
                    mix(image.media_type, &hash);
                    mix(image.data, &hash);
                },
            };
        }
    }
    if (request.tools) |tools| {
        for (tools) |tool| {
            mix(tool.name, &hash);
            mix(tool.description, &hash);
            mix(tool.parameters_json, &hash);
        }
    }
    return hash;
}

fn requestSize(request: providers.ChatRequest) usize {
    var size: usize = 0;
    for (request.messages) |message| {
        size += message.content.len + 16;
        if (message.name) |name| size += name.len;
        if (message.tool_call_id) |id| size += id.len;
        if (message.content_parts) |parts| {
            for (parts) |part| switch (part) {
                .text => |text| size += text.len,
                .image_url => |image| size += image.url.len + 16,
                .image_base64 => |image| size += image.data.len + image.media_type.len + 16,
            };
        }
    }
    if (request.session_id) |id| size += id.len;
    size += request.model.len;
    if (request.reasoning_effort) |effort| size += effort.len;
    if (request.tools) |tools| {
        for (tools) |tool| size += tool.name.len + tool.description.len + tool.parameters_json.len;
    }
    return size;
}

test "typed request gate rejects unproven candidates" {
    var gateway = gateway_mod.Gateway(8){};
    const original = providers.ChatRequest{
        .messages = &.{ providers.ChatMessage.user("long context") },
        .model = "model",
    };
    const candidate = Candidate{
        .request = .{ .messages = &.{providers.ChatMessage.user("short")}, .model = "model" },
        .original_tokens = 10,
        .candidate_tokens = 5,
        .lossless = false,
        .coverage_complete = true,
        .policy_allowed = true,
        .cache_compatible = true,
    };
    const result = try admit(&gateway, 1, 2, original, candidate);
    try std.testing.expect(!result.transformed);
    try std.testing.expectEqualStrings(original.messages[0].content, result.request.messages[0].content);
}

test "typed request gate accepts a proven strict reduction" {
    var gateway = gateway_mod.Gateway(8){};
    const original = providers.ChatRequest{ .messages = &.{providers.ChatMessage.user("a long context")}, .model = "model" };
    const candidate = Candidate{
        .request = .{ .messages = &.{providers.ChatMessage.user("short")}, .model = "model" },
        .original_tokens = 20,
        .candidate_tokens = 5,
        .lossless = true,
        .coverage_complete = true,
        .policy_allowed = true,
        .cache_compatible = true,
    };
    const result = try admit(&gateway, 2, 3, original, candidate);
    try std.testing.expect(result.transformed);
    try std.testing.expectEqualStrings("short", result.request.messages[0].content);
}

test "typed request gate rejects candidates that alter provider metadata" {
    var gateway = gateway_mod.Gateway(8){};
    const original = providers.ChatRequest{
        .messages = &.{providers.ChatMessage.user("a long context")},
        .model = "model",
        .temperature = 0.2,
        .max_tokens = 512,
    };
    const candidate = Candidate{
        .request = .{
            .messages = &.{providers.ChatMessage.user("short")},
            .model = "m",
            .temperature = 0.2,
            .max_tokens = 512,
        },
        .original_tokens = 20,
        .candidate_tokens = 5,
        .lossless = true,
        .coverage_complete = true,
        .policy_allowed = true,
        .cache_compatible = true,
    };
    const result = try admit(&gateway, 3, 4, original, candidate);
    try std.testing.expect(!result.transformed);
    try std.testing.expectEqualStrings("model", result.request.model);
}
