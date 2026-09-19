const std = @import("std");

pub const Phase = enum {
    inspect,
    hypothesize,
    plan,
    mutate,
    verify,
    prove,
    done,
};

pub const ToolClass = enum {
    read,
    mutate,
    verify,
    prove,
    general,
};

pub const PolicyError = error{
    InvalidTransition,
    MissingHypothesis,
    MissingPlan,
    MissingVerification,
    ToolNotAllowedInPhase,
};

pub const State = struct {
    phase: Phase = .inspect,
    hypothesis_recorded: bool = false,
    plan_recorded: bool = false,
    verification_recorded: bool = false,

    pub fn recordHypothesis(self: *State) void {
        self.hypothesis_recorded = true;
    }

    pub fn recordPlan(self: *State) PolicyError!void {
        if (!self.hypothesis_recorded) return error.MissingHypothesis;
        self.plan_recorded = true;
    }

    pub fn recordVerification(self: *State, passed: bool) void {
        self.verification_recorded = passed;
    }

    pub fn transition(self: *State, next: Phase) PolicyError!void {
        const valid = switch (self.phase) {
            .inspect => next == .hypothesize,
            .hypothesize => next == .plan,
            .plan => next == .mutate,
            .mutate => next == .verify,
            .verify => next == .prove,
            .prove => next == .done,
            .done => false,
        };
        if (!valid) return error.InvalidTransition;

        if (next == .plan and !self.hypothesis_recorded) {
            return error.MissingHypothesis;
        }
        if (next == .mutate) {
            if (!self.hypothesis_recorded) return error.MissingHypothesis;
            if (!self.plan_recorded) return error.MissingPlan;
        }
        if ((next == .prove or next == .done) and !self.verification_recorded) {
            return error.MissingVerification;
        }

        self.phase = next;
    }

    pub fn allows(self: State, class: ToolClass) bool {
        return switch (class) {
            .general => self.phase != .done,
            .read => self.phase != .done and self.phase != .mutate,
            .mutate => self.phase == .mutate and self.hypothesis_recorded and self.plan_recorded,
            .verify => self.phase == .verify,
            .prove => self.phase == .prove and self.verification_recorded,
        };
    }

    pub fn requireTool(self: State, class: ToolClass) PolicyError!void {
        if (!self.allows(class)) return error.ToolNotAllowedInPhase;
    }
};

test "mutation is impossible before hypothesis and plan" {
    var state = State{};
    try state.transition(.hypothesize);
    try std.testing.expectError(error.MissingHypothesis, state.transition(.plan));

    state.recordHypothesis();
    try state.transition(.plan);
    try std.testing.expectError(error.MissingPlan, state.transition(.mutate));

    try state.recordPlan();
    try state.transition(.mutate);
    try state.requireTool(.mutate);
}

test "proof requires successful verification evidence" {
    var state = State{
        .phase = .verify,
        .hypothesis_recorded = true,
        .plan_recorded = true,
    };
    try std.testing.expectError(error.MissingVerification, state.transition(.prove));
    state.recordVerification(true);
    try state.transition(.prove);
    try state.requireTool(.prove);
}
