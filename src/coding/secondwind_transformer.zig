//! Provider-neutral adapter that connects a live secondwind Session to Agent's
//! ContextTransformCallback without making proof claims on its behalf.

const std = @import("std");
const providers = @import("../providers/root.zig");
const gate = @import("context_request_gate.zig");
const pipeline = @import("secondwind_pipeline.zig");
const ffi = @import("secondwind_ffi.zig");

pub const EvidenceCallback = *const fn (
    ctx: *anyopaque,
    original: providers.ChatRequest,
    candidate_json: []const u8,
    stats_json: []const u8,
) ?pipeline.Evidence;

pub const Adapter = struct {
    session: *ffi.Session,
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
        var result = pipeline.rewriteCandidate(allocator, self.session, original_json) catch return null;
        defer result.deinit(allocator);
        if (!result.transformed) return null;

        const evidence_ctx = self.evidence_ctx orelse return null;
        const evidence = evidence_cb(evidence_ctx, original, result.request_json, result.stats_json) orelse return null;
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
        messages[i] = .{ .role = message.role.toSlice(), .content = message.content, .name = message.name, .tool_call_id = message.tool_call_id };
    }
    var tools: ?[]WireTool = null;
    defer if (tools) |items| allocator.free(items);
    if (request.tools) |source| {
        tools = try allocator.alloc(WireTool, source.len);
        for (source, 0..) |tool, i| {
            tools.?[i] = .{
                .name = tool.name,
                .description = tool.description,
                .parameters_json = "{}" }},
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
    try std.testing.expectEqual(@as(usize, 1), decoded.tools.?.len);
    try std.testing.expectEqualStrings("lookup", decoded.tools.?[0].name);
    try std.testing.try std.testing.expectEqualStrings("{}", decoded.tools.?[0].parameters_json);
}
