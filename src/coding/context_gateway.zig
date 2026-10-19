//! Provider-neutral Context Gateway contract mirrored from AllasCode.
//!
//! This module is a tested boundary primitive, not yet wired into ChappieClaw's
//! provider serialization or inference loop. Callers must supply trustworthy
//! validation results; this module does not prove semantic losslessness itself.
//! Payloads are borrowed, and audit records intentionally omit raw payloads.
//! Fingerprints are non-cryptographic correlation identifiers only.

const std = @import("std");

pub const Phase = enum(u8) {
    request_admitted,
    request_fallback,
    response_admitted,
    response_rejected,
};

pub const ResponseKind = enum(u8) {
    text,
    structured,
    tool_call,
};

pub const Decision = enum(u8) {
    transformed,
    original_passthrough,
    deliver,
    execute_authorized_tool,
    reject,
};

pub const Validation = struct {
    lossless: bool = false,
    coverage_complete: bool = false,
    policy_allowed: bool = false,
    cache_compatible: bool = false,
    original_tokens: u32 = 0,
    candidate_tokens: u32 = 0,
};

pub const Request = struct {
    request_id: u64,
    intent_id: u128,
    bytes: []const u8,
    decision: Decision,
};

pub const Response = struct {
    request_id: u64,
    bytes: []const u8,
    kind: ResponseKind,
    decision: Decision,
};

/// Payload-free audit metadata. Never stores prompts, outputs, or tool arguments.
pub const Record = struct {
    sequence: u64,
    request_id: u64,
    intent_id: u128,
    phase: Phase,
    original_fingerprint: u64,
    candidate_fingerprint: u64,
    original_bytes: u32,
    candidate_bytes: u32,
    original_tokens: u32,
    candidate_tokens: u32,
    accepted: bool,
};

pub fn Gateway(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        records: [capacity]Record = undefined,
        len: usize = 0,
        next_sequence: u64 = 1,
        next_request_id: u64 = 1,

        pub fn beforeInference(
            self: *Self,
            intent_id: u128,
            original: []const u8,
            candidate: []const u8,
            validation: Validation,
        ) error{AuditCapacityExceeded}!Request {
            if (self.len == capacity) return error.AuditCapacityExceeded;

            const request_id = self.next_request_id;
            self.next_request_id += 1;

            const accept = validation.lossless and
                validation.coverage_complete and
                validation.policy_allowed and
                validation.cache_compatible and
                validation.candidate_tokens < validation.original_tokens and
                candidate.len < original.len;

            const chosen = if (accept) candidate else original;
            self.append(.{
                .sequence = 0,
                .request_id = request_id,
                .intent_id = intent_id,
                .phase = if (accept) .request_admitted else .request_fallback,
                .original_fingerprint = fingerprint(original),
                .candidate_fingerprint = fingerprint(candidate),
                .original_bytes = boundedLen(original.len),
                .candidate_bytes = boundedLen(candidate.len),
                .original_tokens = validation.original_tokens,
                .candidate_tokens = validation.candidate_tokens,
                .accepted = accept,
            });

            return .{
                .request_id = request_id,
                .intent_id = intent_id,
                .bytes = chosen,
                .decision = if (accept) .transformed else .original_passthrough,
            };
        }

        /// Must run before a response is exposed or a tool call is executed.
        pub fn beforeReturn(
            self: *Self,
            request_id: u64,
            intent_id: u128,
            bytes: []const u8,
            kind: ResponseKind,
            schema_valid: bool,
            tool_authorized: bool,
        ) error{AuditCapacityExceeded}!Response {
            if (self.len == capacity) return error.AuditCapacityExceeded;

            const accepted = schema_valid and (kind != .tool_call or tool_authorized);
            self.append(.{
                .sequence = 0,
                .request_id = request_id,
                .intent_id = intent_id,
                .phase = if (accepted) .response_admitted else .response_rejected,
                .original_fingerprint = fingerprint(bytes),
                .candidate_fingerprint = fingerprint(bytes),
                .original_bytes = boundedLen(bytes.len),
                .candidate_bytes = boundedLen(bytes.len),
                .original_tokens = 0,
                .candidate_tokens = 0,
                .accepted = accepted,
            });

            return .{
                .request_id = request_id,
                .bytes = bytes,
                .kind = kind,
                .decision = if (!accepted) .reject else if (kind == .tool_call) .execute_authorized_tool else .deliver,
            };
        }

        pub fn audit(self: *const Self) []const Record {
            return self.records[0..self.len];
        }

        fn append(self: *Self, record: Record) void {
            self.records[self.len] = .{
                .sequence = self.next_sequence,
                .request_id = record.request_id,
                .intent_id = record.intent_id,
                .phase = record.phase,
                .original_fingerprint = record.original_fingerprint,
                .candidate_fingerprint = record.candidate_fingerprint,
                .original_bytes = record.original_bytes,
                .candidate_bytes = record.candidate_bytes,
                .original_tokens = record.original_tokens,
                .candidate_tokens = record.candidate_tokens,
                .accepted = record.accepted,
            };
            self.len += 1;
            self.next_sequence += 1;
        }
    };
}

fn boundedLen(len: usize) u32 {
    return @intCast(@min(len, @as(usize, std.math.maxInt(u32))));
}

fn fingerprint(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

test "only validated net reductions replace the original request" {
    var gateway = Gateway(8){};
    const original = "{\"items\":[1,2,3,4]}";
    const candidate = "{\"i\":[1,2,3,4]}";
    const request = try gateway.beforeInference(42, original, candidate, .{
        .lossless = true,
        .coverage_complete = true,
        .policy_allowed = true,
        .cache_compatible = true,
        .original_tokens = 12,
        .candidate_tokens = 8,
    });
    try std.testing.expectEqual(Decision.transformed, request.decision);
    try std.testing.expectEqualStrings(candidate, request.bytes);
    try std.testing.expectEqual(@as(usize, 1), gateway.audit().len);
    try std.testing.expect(gateway.audit()[0].accepted);
}

test "missing coverage or savings falls back to byte-identical original" {
    var gateway = Gateway(8){};
    const original = "{\"value\":123}";
    const candidate = "{\"v\":123}";
    const request = try gateway.beforeInference(9, original, candidate, .{
        .lossless = true,
        .coverage_complete = false,
        .policy_allowed = true,
        .cache_compatible = true,
        .original_tokens = 10,
        .candidate_tokens = 5,
    });
    try std.testing.expectEqual(Decision.original_passthrough, request.decision);
    try std.testing.expectEqualStrings(original, request.bytes);
    try std.testing.expect(!gateway.audit()[0].accepted);
}

test "malformed responses and unauthorized tool calls are rejected" {
    var gateway = Gateway(8){};
    const denied = try gateway.beforeReturn(1, 7, "{\"tool\":\"delete\"}", .tool_call, true, false);
    try std.testing.expectEqual(Decision.reject, denied.decision);

    const malformed = try gateway.beforeReturn(1, 7, "{", .structured, false, false);
    try std.testing.expectEqual(Decision.reject, malformed.decision);

    const text = try gateway.beforeReturn(1, 7, "done", .text, true, false);
    try std.testing.expectEqual(Decision.deliver, text.decision);
    try std.testing.expectEqual(@as(usize, 3), gateway.audit().len);
}

test "audit capacity fails closed" {
    var gateway = Gateway(1){};
    _ = try gateway.beforeInference(1, "original", "small", .{
        .lossless = true,
        .coverage_complete = true,
        .policy_allowed = true,
        .cache_compatible = true,
        .original_tokens = 4,
        .candidate_tokens = 1,
    });
    try std.testing.expectError(error.AuditCapacityExceeded, gateway.beforeReturn(1, 1, "ok", .text, true, false));
}

test "audit retains metadata but never payload bytes" {
    var gateway = Gateway(2){};
    _ = try gateway.beforeInference(77, "SECRET_ORIGINAL_PROMPT", "SECRET_CANDIDATE", .{});
    const record = gateway.audit()[0];
    try std.testing.expectEqual(@as(u128, 77), record.intent_id);
    try std.testing.expectEqual(@as(u32, 22), record.original_bytes);
    try std.testing.expectEqual(@as(u32, 16), record.candidate_bytes);
    try std.testing.expect(!@hasField(Record, "bytes"));
}
