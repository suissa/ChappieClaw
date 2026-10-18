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
        .policy_allowed = c.policy_allowed,
        .cache_compatible = c.cache_compatible,
        .original_tokens = c.original_tokens,
        .candidate_tokens = c.candidate_tokens,
    };

    const original_marker_len = @max(@as(usize, 1), original_bytes);
    const candidate_marker_len = @max(@as(usize, 1), candidate_bytes);
    const original_marker = try std.heap.page_allocator.alloc(u8, original_marker_len);
    defer std.heap.page_allocator.free(original_marker);
    const candidate_marker = try std.heap.page_allocator.alloc(u8, candidate_marker_len);
    defer std.heap.page_allocator.free(candidate_marker);
    @memset(original_marker, 0);
    @memset(candidate_marker, 0);

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
