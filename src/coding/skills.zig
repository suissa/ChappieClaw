const std = @import("std");

pub const SkillKind = enum {
    semantics,
    authoring,
    healing,
};

pub const Retrieval = struct {
    symbols: []const []const u8 = &.{},
    concepts: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
};

pub const Authority = struct {
    readable_paths: []const []const u8 = &.{},
    writable_paths: []const []const u8 = &.{},
};

/// Canonical adapter surface for AllasCode atomic Action SKILLs.
/// The human-readable SKILL.md body remains outside this struct; this is only
/// resolver metadata and authority.
pub const Manifest = struct {
    id: []const u8,
    canonical_label: []const u8,
    kind: SkillKind,
    language: ?[]const u8 = null,
    retrieval: Retrieval = .{},
    requires: []const []const u8 = &.{},
    related: []const []const u8 = &.{},
    authority: Authority = .{},
    version: []const u8 = "1.0.0",
};

pub const Query = struct {
    canonical_label: ?[]const u8 = null,
    language: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    concept: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
};

pub const ResolverConfig = struct {
    max_skills: usize = 8,
    max_context_bytes: usize = 48 * 1024,
};

fn containsExact(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

/// Deterministic score. Canonical identity outranks language, which outranks
/// secondary semantic signals.
pub fn score(manifest: Manifest, query: Query) u32 {
    var total: u32 = 0;

    if (query.canonical_label) |value| {
        if (std.mem.eql(u8, manifest.canonical_label, value)) total += 100;
    }
    if (query.language) |value| {
        if (manifest.language) |language| {
            if (std.ascii.eqlIgnoreCase(language, value)) total += 30;
        }
    }
    if (query.symbol) |value| {
        if (containsExact(manifest.retrieval.symbols, value)) total += 20;
    }
    if (query.concept) |value| {
        if (containsExact(manifest.retrieval.concepts, value)) total += 15;
    }
    if (query.diagnostic) |value| {
        if (containsExact(manifest.retrieval.errors, value)) total += 25;
    }

    return total;
}

pub fn writable(manifest: Manifest, path: []const u8) bool {
    return containsExact(manifest.authority.writable_paths, path);
}

test "canonical Action skill dominates resolver score" {
    const manifest = Manifest{
        .id = "action.dynamic-data.normalize.semantics",
        .canonical_label = "DynamicData.Normalize",
        .kind = .semantics,
        .language = "zig",
        .retrieval = .{
            .symbols = &.{"Normalize"},
            .concepts = &.{"normalization"},
            .errors = &.{"TypeConflict"},
        },
    };

    const value = score(manifest, .{
        .canonical_label = "DynamicData.Normalize",
        .language = "zig",
        .symbol = "Normalize",
        .diagnostic = "TypeConflict",
    });
    try std.testing.expectEqual(@as(u32, 175), value);
}

test "authoring authority is explicit" {
    const manifest = Manifest{
        .id = "action.x.authoring",
        .canonical_label = "X.Do",
        .kind = .authoring,
        .authority = .{ .writable_paths = &.{"implementation.zig"} },
    };
    try std.testing.expect(writable(manifest, "implementation.zig"));
    try std.testing.expect(!writable(manifest, "contract.zig"));
}
