const std = @import("std");

pub const ProofState = enum {
    pending,
    passed,
    failed,
    inconclusive,
};

/// Metadata-only audit record. Source contents and secrets are intentionally
/// excluded; hashes and identifiers are enough to reproduce a run safely.
pub const RunLineage = struct {
    run_id: []const u8,
    task_id: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    hypothesis_hash: ?[]const u8 = null,
    plan_hash: ?[]const u8 = null,
    inspected_file_hashes: []const []const u8 = &.{},
    selected_skill_ids: []const []const u8 = &.{},
    mutation_hashes: []const []const u8 = &.{},
    verification_commands: []const []const u8 = &.{},
    proof_state: ProofState = .pending,

    pub fn hasProvenance(self: RunLineage) bool {
        return self.selected_skill_ids.len > 0 or self.inspected_file_hashes.len > 0;
    }
};

test "lineage records provenance without requiring source payloads" {
    const lineage = RunLineage{
        .run_id = "run-1",
        .inspected_file_hashes = &.{"sha256:file-a"},
        .selected_skill_ids = &.{"action.x.semantics"},
    };
    try std.testing.expect(lineage.hasProvenance());
}
