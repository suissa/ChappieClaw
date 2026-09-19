const std = @import("std");

pub const ProfileKind = enum {
    code_manager,
    code_healer,
    healing_verifier,
};

pub const Capability = enum {
    inspect,
    form_hypothesis,
    plan,
    mutate,
    execute_tests,
    verify,
    prove,
};

pub const Profile = struct {
    name: []const u8,
    kind: ProfileKind,
    capabilities: []const Capability,
    inherit_reasoning_context: bool,
};

pub const code_manager = Profile{
    .name = "CodeManager",
    .kind = .code_manager,
    .capabilities = &.{ .inspect, .form_hypothesis, .plan },
    .inherit_reasoning_context = false,
};

pub const code_healer = Profile{
    .name = "CodeHealer",
    .kind = .code_healer,
    .capabilities = &.{ .inspect, .mutate, .execute_tests },
    .inherit_reasoning_context = false,
};

pub const healing_verifier = Profile{
    .name = "HealingVerifier",
    .kind = .healing_verifier,
    .capabilities = &.{ .inspect, .execute_tests, .verify, .prove },
    // Independent verification is a hard authority boundary.
    .inherit_reasoning_context = false,
};

pub fn hasCapability(profile: Profile, capability: Capability) bool {
    for (profile.capabilities) |candidate| {
        if (candidate == capability) return true;
    }
    return false;
}

test "only healer can mutate" {
    try std.testing.expect(!hasCapability(code_manager, .mutate));
    try std.testing.expect(hasCapability(code_healer, .mutate));
    try std.testing.expect(!hasCapability(healing_verifier, .mutate));
}

test "verifier never inherits healer reasoning" {
    try std.testing.expect(!healing_verifier.inherit_reasoning_context);
}
