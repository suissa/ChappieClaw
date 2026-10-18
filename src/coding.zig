//! Coding-agent specialization for AllasCode.
//!
//! This module keeps generic NullClaw behavior intact while exposing an
//! opt-in coding lifecycle, atomic-skill contracts, tool catalog, authority
//! profiles, healing knowledge promotion, lineage, and ACP session metadata.

pub const policy = @import("coding/policy.zig");
pub const skills = @import("coding/skills.zig");
pub const tools = @import("coding/tools.zig");
pub const profiles = @import("coding/profiles.zig");
pub const healing = @import("coding/healing.zig");
pub const lineage = @import("coding/lineage.zig");
pub const acp = @import("coding/acp.zig");
pub const safety = @import("coding/safety.zig");
pub const context_gateway = @import("coding/context_gateway.zig");
pub const context_stream_gate = @import("coding/context_stream_gate.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
