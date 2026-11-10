//! Strict output boundary for streaming model responses.
//!
//! Provider streaming APIs invoke callbacks before the complete response exists.
//! This adapter buffers deltas and exposes them only after the Context Gateway
//! validates the completed response. Strict validation takes precedence over latency.

const std = @import("std");
const providers = @import("../providers/root.zig");
const context_gateway = @import("context_gateway.zig");

pub const Gate = struct {
    allocator: std.mem.Allocator,
    downstream: providers.StreamCallback,
    downstream_ctx: *anyopaque,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, downstream: providers.StreamCallback, downstream_ctx: *anyopaque) Gate {
        return .{ .allocator = allocator, .downstream = downstream, .downstream_ctx = downstream_ctx };
    }

    /// Provider callback. Never forwards a partial delta.
    pub fn onChunk(ctx: *anyopaque, chunk: providers.StreamChunk) void {
        const self: *Gate = @ptrCast(@alignCast(ctx));
        if (self.failed) return;
        self.buffer.appendSlice(self.allocator, chunk.delta) catch {
            self.failed = true;
        };
    }

    /// Discard buffered data from a failed provider attempt before retrying.
    pub fn reset(self: *Gate) void {
        self.buffer.clearRetainingCapacity();
        self.failed = false;
    }

    /// Validate and publish the complete response exactly once.
    pub fn finish(self: *Gate, gateway: anytype, request_id: u64, intent_id: u128) !void {
        if (self.failed) return error.OutOfMemory;
        const admitted = try gateway.beforeReturn(request_id, intent_id, self.buffer.items, .text, true, false);
        if (admitted.decision == .reject) return error.ContextGatewayRejected;
        if (admitted.bytes.len > 0) self.downstream(self.downstream_ctx, providers.StreamChunk.textDelta(admitted.bytes));
        self.downstream(self.downstream_ctx, providers.StreamChunk.finalChunk());
    }

    pub fn deinit(self: *Gate) void {
        self.buffer.deinit(self.allocator);
    }
};

test "stream gate buffers deltas and emits only after validation" {
    const State = struct {
        chunks: usize = 0,
        text_len: usize = 0,
        finals: usize = 0,
        fn callback(ctx: *anyopaque, chunk: providers.StreamChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (chunk.is_final) self.finals += 1 else { self.chunks += 1; self.text_len += chunk.delta.len; }
        }
    };
    var state = State{};
    var gate = Gate.init(std.testing.allocator, State.callback, &state);
    defer gate.deinit();
    Gate.onChunk(&gate, providers.StreamChunk.textDelta("hel"));
    Gate.onChunk(&gate, providers.StreamChunk.textDelta("lo"));
    try std.testing.expectEqual(@as(usize, 0), state.chunks);
    var gateway = context_gateway.Gateway(8){};
    try gate.finish(&gateway, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), state.chunks);
    try std.testing.expectEqual(@as(usize, 5), state.text_len);
    try std.testing.expectEqual(@as(usize, 1), state.finals);
}
