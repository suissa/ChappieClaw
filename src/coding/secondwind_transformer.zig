//! Provider-neutral adapter that connects a live secondwind Session to Agent's
//! ContextTransformCallback without making proof claims on its behalf.

const std = @import("std");
const providers = @import("../providers/root.zig");
const gate = @import("context_request_gate.zig");
const pipeline = @import("secondwind_pipeline.zig");
const ffi = @import("secondwind_ffi.zig");
const gateway = @import("context_gateway.zig");

pub const EvidenceCallback = *const fn (
    ctx: *anyopaque,
    original: providers.ChatRequest,
    candidate_json: []const u8,
    stats_json: []const u8,
) ?pipeline.Evidence;

pub const Adapter = struct {
    session: *ffi.Session,
    gateway_ptr: *gateway.Gateway(512),
    evidence_callback: ?EvidenceCallback = null,
    evidence_ctx: ?*anyopaque = null,

    /// ContextTransformCallback implementation. The callback is deliberately
    /// fail-closed: without independent evidence it returns null and the Agent
    /// sends the original request.
    pub fn transform(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        original: providers.ChatRequest,
    ) anyerror!?gate.Candidate {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const original_json = try serializeRequest(allocator, original);
        defer allocator.free(original_json);

        const evidence_cb = self.evidence_callback orelse return null;
        const result = pipeline.rewriteForInference(
            allocator,
            self.session,
            self.gateway_ptr,
            0,
            original_json,
            null,
        ) catch return null;
        defer {
            var owned = result;
            owned.deinit(allocator);
        }

        if (!result.transformed) return null;
        const evidence = evidence_cb(self.evidence_ctx orelse return null, original, result.request_json, result.stats_json) orelse return null;
        if (!evidence.lossless or !evidence.coverage_complete or !evidence.policy_allowed or !evidence.cache_compatible) return null;
        if (evidence.candidate_tokens >= evidence.original_tokens) return null;

        const candidate = try deserializeRequest(allocator, result.request_json);
        return .{
            .request = candidate,
            .original_tokens = evidence.original_tokens,
            .candidate_tokens = evidence.candidate_tokens,
            .lossless = evidence.lossless,
            .coverage_complete = evidence.coverage_complete,
            .policy_allowed = evidence.policy_allowed,
            .cache_compatible = evidence.cache_compatible,
        };
    }
};

const WireMessage = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};

const WireTool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

const WireRequest = struct {
    messages: []const WireMessage,
    session_id: ?[]const u8 = null,
    model: []const u8,
    temperature: f64,
    max_tokens: ?u32 = null,
    tools: ?[]const WireTool = null,
    timeout_secs: u64 = 0,
    reasoning_effort: ?[]const u8 = null,
    include_reasoning: ?bool = null,
};

fn serializeRequest(allocator: std.mem.Allocator, request: providers.ChatRequest) ![]u8 {
    for (request.messages) |message| {
        if (message.content_parts != null) return error.UnsupportedMultimodalRequest;
    }

    var messages = try allocator.alloc(WireMessage, request.messages.len);
    defer allocator.free(messages);
    for (request.messages, 0..) |message, i| {
        messages[i] = .{
            .role = message.role.toSlice(),
            .content = message.content,
            .name = message.name,
            .tool_call_id = message.tool_call_id,
        };
    }

    var tools: ?[]WireTool = null;
    defer if (tools) |items| allocator.free(items);
    if (request.tools) |source| {
        tools = try allocator.alloc(WireTool, source.len);
        for (source, 0..) |tool, i| {
            tools.?[i] = .{
                .name = tool.name,
                .description = tool.description,
                .parameters_json = tool.parameters_json,
            };
        }
    }

    const wire = WireRequest{
        .messages = messages,
        .session_id = request.session_id,
        .model = request.model,
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .tools = tools,
        .timeout_secs = request.timeout_secs,
        .reasoning_effort = request.reasoning_effort,
        .include_reasoning = request.include_reasoning,
    };
    return std.json.Stringify.valueAlloc(allocator, wire, .{});
}

fn deserializeRequest(allocator: std.mem.Allocator, json: []const u8) !providers.ChatRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSecondwindRequest;

    const messages_value = parsed.value.object.get("messages") orelse return error.InvalidSecondwindRequest;
    if (messages_value != .array) return error.InvalidSecondwindRequest;

    const messages = try allocator.alloc(providers.ChatMessage, messages_value.array.items.len);
    for (messages_value.array.items, 0..) |value, i| {
        if (value != .object) return error.InvalidSecondwindRequest;
        const role_value = value.object.get("role") orelse return error.InvalidSecondwindRequest;
        const content_value = value.object.get("content") orelse return error.InvalidSecondwindRequest;
        if (role_value != .string or content_value != .string) return error.InvalidSecondwindRequest;
        const role = providers.Role.fromSlice(role_value.string) orelse return error.InvalidSecondwindRequest;
        messages[i] = .{
            .role = role,
            .content = try allocator.dupe(u8, content_value.string),
            .name = try duplicateOptional(allocator, value.object.get("name")),
            .tool_call_id = try duplicateOptional(allocator, value.object.get("tool_call_id")),
        };
    }

    const model = try duplicateRequired(allocator, parsed.value.object.get("model"));
    return .{
        .messages = messages,
        .session_id = try duplicateOptional(allocator, parsed.value.object.get("session_id")),
        .model = model,
        .temperature = numberOrDefault(parsed.value.object.get("temperature"), 0.7),
        .max_tokens = uintOrNull(parsed.value.object.get("max_tokens")),
        .timeout_secs = uintOrDefault(parsed.value.object.get("timeout_secs"), 0),
        .reasoning_effort = try duplicateOptional(allocator, parsed.value.object.get("reasoning_effort")),
        .include_reasoning = boolOrNull(parsed.value.object.get("include_reasoning")),
        .tools = null,
    };
}

fn duplicateRequired(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const v = value orelse return error.InvalidSecondwindRequest;
    if (v != .string) return error.InvalidSecondwindRequest;
    return allocator.dupe(u8, v.string);
}

fn duplicateOptional(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const v = value orelse return null;
    if (v != .string) return error.InvalidSecondwindRequest;
    return try allocator.dupe(u8, v.string);
}

fn numberOrDefault(value: ?std.json.Value, fallback: f64) f64 {
    const v = value orelse return fallback;
    return switch (v) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => fallback,
    };
}

fn uintOrNull(value: ?std.json.Value) ?u32 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

fn uintOrDefault(value: ?std.json.Value, fallback: u64) u64 {
    const v = value orelse return fallback;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else fallback,
        else => fallback,
    };
}

fn boolOrNull(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

test "wire adapter declines multimodal requests" {
    const request = providers.ChatRequest{
        .messages = &.{.{ .role = .user, .content = "x", .content_parts = &.{} }},
        .model = "m",
    };
    try std.testing.expectError(error.UnsupportedMultimodalRequest, serializeRequest(std.testing.allocator, request));
}

test "wire adapter round trips supported request metadata" {
    const request = providers.ChatRequest{
        .messages = &.{providers.ChatMessage.user("x")},
        .session_id = "session",
        .model = "m",
        .temperature = 0.2,
        .max_tokens = 42,
        .timeout_secs = 9,
        .reasoning_effort = "low",
        .include_reasoning = true,
    };
    const json = try serializeRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(json);
    const decoded = try deserializeRequest(std.testing.allocator, json);
    try std.testing.expectEqualStrings("x", decoded.messages[0].content);
    try std.testing.expectEqualStrings("session", decoded.session_id.?);
    try std.testing.expectEqualStrings("m", decoded.model);
    try std.testing.expectEqual(@as(u32, 42), decoded.max_tokens.?);
    try std.testing.expectEqual(@as(u64, 9), decoded.timeout_secs);
}
