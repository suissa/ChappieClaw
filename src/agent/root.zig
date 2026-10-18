//! Agent core — struct definition, turn loop, tool execution.
//!
//! Sub-modules: dispatcher.zig (tool call parsing), compaction.zig (history
//! compaction/trimming), cli.zig (CLI entry point + REPL), prompt.zig
//! (system prompt), memory_loader.zig (memory enrichment).

const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const Config = @import("../config.zig").Config;
const config_types = @import("../config_types.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatResponse = providers.ChatResponse;
const ContentPart = providers.ContentPart;
const ToolSpec = providers.ToolSpec;
const redaction = @import("../redaction.zig");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const bootstrap_mod = @import("../bootstrap/root.zig");
const capabilities_mod = @import("../capabilities.zig");
const multimodal = @import("../multimodal.zig");
const platform = @import("../platform.zig");
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const util = @import("../util.zig");
const verbose_mod = @import("../verbose.zig");
const cost_mod = @import("../cost.zig");
const context_gateway_mod = @import("../coding/context_gateway.zig");

const cache = memory_mod.cache;
pub const dispatcher = @import("dispatcher.zig");
pub const compaction = @import("compaction.zig");
pub const context_tokens = @import("context_tokens.zig");
pub const max_tokens_resolver = @import("max_tokens.zig");
pub const prompt = @import("prompt.zig");
pub const memory_loader = @import("memory_loader.zig");
pub const commands = @import("commands.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum agentic tool-use iterations per user message.
const DEFAULT_MAX_TOOL_ITERATIONS: u32 = 25;
const MAX_MID_TURN_INJECTION_FOLLOWUPS: u32 = 8;

/// Maximum non-system messages before trimming.
const DEFAULT_MAX_HISTORY: u32 = 50;

pub fn estimate_text_tokens(text: []const u8) u32 {
    return @intCast((text.len + 3) / 4);
}

// ─── Progress hints ──────────────────────────────────────────────────────────

/// Progress hint emitted during a turn. For tool-call starts, text is the tool name.
pub const ProgressHint = struct {
    text: []const u8,
};

/// Callback invoked for each progress hint. Same lifetime rules as StreamCallback.
pub const ProgressCallback = *const fn (ctx: *anyopaque, hint: ProgressHint) void;

/// Sink wrapping a ProgressCallback + context pointer.
pub const ProgressSink = struct {
    callback: ProgressCallback,
    ctx: *anyopaque,

    pub fn emit(self: ProgressSink, hint: ProgressHint) void {
        self.callback(self.ctx, hint);
    }
};

/// Callback invoked at each tool-loop boundary to drain a pending mid-turn injection.
/// Returns an owned slice allocated with the provided allocator, or null if empty.
pub const DrainCallback = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8;

/// A streaming sink used by the Context Gateway boundary. Provider chunks are buffered
/// until the provider finishes, so no unvalidated partial output reaches the downstream
/// callback. This intentionally trades streaming latency for a strict output boundary.
const ContextStreamGate = struct {
    allocator: std.mem.Allocator,
    downstream: providers.StreamCallback,
    downstream_ctx: *anyopaque,
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    fn callback(ctx: *anyopaque, chunk: providers.StreamChunk) void {
        const self: *ContextStreamGate = @ptrCast(@alignCast(ctx));
        self.buffer.appendSlice(self.allocator, chunk.delta) catch return;
    }

    fn deinit(self: *ContextStreamGate) void {
        self.buffer.deinit(self.allocator);
    }

    fn emitValidated(self: *ContextStreamGate, gateway: anytype, request_id: u64, intent_id: u128) !void {
        const bytes = self.buffer.items;
        const admitted = try gateway.beforeReturn(request_id, intent_id, bytes, .text, true, false);
        if (admitted.decision == .reject) return error.ContextGatewayRejected;
        if (admitted.bytes.len > 0) {
            self.downstream(self.downstream_ctx, providers.StreamChunk.textDelta(admitted.bytes));
        }
        self.downstream(self.downstream_ctx, providers.StreamChunk.finalChunk());
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Agent
// ═══════════════════════════════════════════════════════════════════════════
