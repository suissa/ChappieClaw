const std = @import("std");
const policy = @import("policy.zig");

/// ACP-visible metadata for a coding session. This intentionally exposes state,
/// not hidden reasoning text.
pub const SessionState = struct {
    coding_mode: bool = true,
    workspace: []const u8,
    phase: policy.Phase = .inspect,
    hypothesis_recorded: bool = false,
    last_diagnostic_count: usize = 0,
    verification_passed: bool = false,

    pub fn canMutate(self: SessionState) bool {
        return self.coding_mode and
            self.phase == .mutate and
            self.hypothesis_recorded;
    }
};

test "ACP session cannot bypass mutation phase" {
    const inspect_session = SessionState{
        .workspace = "/workspace",
        .phase = .inspect,
        .hypothesis_recorded = true,
    };
    try std.testing.expect(!inspect_session.canMutate());

    const mutate_session = SessionState{
        .workspace = "/workspace",
        .phase = .mutate,
        .hypothesis_recorded = true,
    };
    try std.testing.expect(mutate_session.canMutate());
}
