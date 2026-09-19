const std = @import("std");

pub const VerificationState = enum {
    passed,
    failed,
    inconclusive,
};

pub const CandidateState = enum {
    candidate,
    validated,
    promoted,
    rejected,
};

pub const HealingCandidate = struct {
    id: []const u8,
    failure_signature: []const u8,
    causal_hypothesis: []const u8,
    fix_pattern: []const u8,
    verification: VerificationState,
    state: CandidateState = .candidate,

    pub fn validate(self: *HealingCandidate) error{VerificationRequired}!void {
        if (self.verification != .passed) return error.VerificationRequired;
        self.state = .validated;
    }

    pub fn promote(self: *HealingCandidate) error{NotValidated}!void {
        if (self.state != .validated) return error.NotValidated;
        self.state = .promoted;
    }

    pub fn trusted(self: HealingCandidate) bool {
        return self.state == .promoted and self.verification == .passed;
    }
};

test "failed or inconclusive healing cannot become trusted knowledge" {
    var failed = HealingCandidate{
        .id = "candidate-1",
        .failure_signature = "TypeConflict",
        .causal_hypothesis = "schema mismatch",
        .fix_pattern = "normalize before persistence",
        .verification = .failed,
    };
    try std.testing.expectError(error.VerificationRequired, failed.validate());
    try std.testing.expect(!failed.trusted());

    var passed = HealingCandidate{
        .id = "candidate-2",
        .failure_signature = "TypeConflict",
        .causal_hypothesis = "schema mismatch",
        .fix_pattern = "normalize before persistence",
        .verification = .passed,
    };
    try passed.validate();
    try passed.promote();
    try std.testing.expect(passed.trusted());
}
