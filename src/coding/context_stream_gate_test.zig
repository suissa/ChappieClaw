//! Regression tests for Context Gateway stream admission and retry isolation.
const std = @import("std");
const providers = @import("../providers/root.zig");
const context_gateway = @import("context_gateway.zig");
const stream_gate = @import("context_stream_gate.zig");

const Recorder = struct {
    chunks: usize = 0,
    finals: usize = 0,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn callback(ctx: *anyopaque, chunk: providers.StreamChunk) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (chunk.is_final) {
            self.finals += 1;
        } else {
            self.chunks += 1;
            self.bytes.appendSlice(std.testing.allocator, chunk.delta) catch unreachable;
        }
    }

    fn deinit(self: *@This()) void {
        self.bytes.deinit(std.testing.allocator);
    }
};

test "stream gate reset discards a failed attempt before retry" {
    var recorder = Recorder{};
    defer recorder.deinit();

    var gate = stream_gate.Gate.init(std.testing.allocator, Recorder.callback, &recorder);
    defer gate.deinit();

    stream_gate.Gate.onChunk(&gate, providers.StreamChunk.textDelta("partial response"));
    gate.reset();
    stream_gate.Gate.onChunk(&gate, providers.StreamChunk.textDelta("complete response"));

    var gateway = context_gateway.Gateway(8){};
    try gate.finish(&gateway, 1, 2);

    try std.testing.expectEqualStrings("complete response", recorder.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), recorder.chunks);
    try std.testing.expectEqual(@as(usize, 1), recorder.finals);
}

test "stream gate does not publish data if final admission has no audit capacity" {
    var recorder = Recorder{};
    defer recorder.deinit();

    var gate = stream_gate.Gate.init(std.testing.allocator, Recorder.callback, &recorder);
    defer gate.deinit();
    stream_gate.Gate.onChunk(&gate, providers.StreamChunk.textDelta("must remain private"));

    var gateway = context_gateway.Gateway(0){};
    try std.testing.expectError(error.AuditCapacityExceeded, gate.finish(&gateway, 1, 2));
    try std.testing.expectEqual(@as(usize, 0), recorder.chunks);
    try std.testing.expectEqual(@as(usize, 0), recorder.finals);
}

test "stream gate emits an empty final response without inventing content" {
    var recorder = Recorder{};
    defer recorder.deinit();

    var gate = stream_gate.Gate.init(std.testing.allocator, Recorder.callback, &recorder);
    defer gate.deinit();

    var gateway = context_gateway.Gateway(8){};
    try gate.finish(&gateway, 1, 2);

    try std.testing.expectEqual(@as(usize, 0), recorder.chunks);
    try std.testing.expectEqual(@as(usize, 0), recorder.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 1), recorder.finals);
}
