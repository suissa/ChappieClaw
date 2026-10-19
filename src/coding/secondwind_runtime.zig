//! Explicit owner for the Secondwind shared library, session, and Context Gateway.
//!
//! Nothing is loaded unless the host calls init(). The owner must outlive every
//! provider configured through attach(); deinit() detaches no providers, so callers
//! must disable/destroy those providers before deinitializing this owner.

const std = @import("std");
const ffi = @import("secondwind_ffi.zig");
const compatible = @import("../providers/compatible.zig");

pub const Gateway = compatible.SecondwindGateway;

pub const Config = struct {
    library_path: []const u8,
    session_json: []const u8 = "{}",
    intent_id: u128,
    policy_allowed: bool = false,
    cache_compatible: bool = false,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    library: ffi.LoadedLibrary,
    session: ffi.Session,
    gateway: Gateway = .{},
    intent_id: u128,
    policy_allowed: bool,
    cache_compatible: bool,
    active: bool = true,

    /// Opens only the exact library path supplied by the host and creates one
    /// session. On session creation failure the library is immediately closed.
    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        if (config.library_path.len == 0) return error.SecondwindLibraryPathRequired;

        var library = try ffi.LoadedLibrary.open(config.library_path);
        errdefer library.close();

        const session = try ffi.Session.init(library.api, config.session_json);
        return .{
            .allocator = allocator,
            .library = library,
            .session = session,
            .intent_id = config.intent_id,
            .policy_allowed = config.policy_allowed,
            .cache_compatible = config.cache_compatible,
        };
    }

    /// Attach the owner to an OpenAI-compatible provider. The provider borrows
    /// pointers; this Runtime must remain alive until disableSecondwind() is
    /// called on that provider and no inference can still be in flight.
    pub fn attach(self: *Runtime, provider: *compatible.OpenAiCompatibleProvider) void {
        if (!self.active) {
            provider.disableSecondwind();
            return;
        }
        provider.configureSecondwind(
            &self.session,
            &self.gateway,
            self.intent_id,
            self.policy_allowed,
            self.cache_compatible,
        );
    }

    /// Stop future use through this owner. Existing provider pointers are not
    /// silently assumed safe: callers must disable them before deinit().
    pub fn disable(self: *Runtime) void {
        self.active = false;
    }

    /// Required order: providers detached by their owner first, then session,
    /// then shared library. Never close the library while a session is alive.
    pub fn deinit(self: *Runtime) void {
        self.session.deinit();
        self.library.close();
        self.active = false;
    }
};

test "runtime configuration is opt-in and requires an explicit library path" {
    try std.testing.expectError(
        error.SecondwindLibraryPathRequired,
        Runtime.init(std.testing.allocator, .{
            .library_path = "",
            .intent_id = 1,
        }),
    );
}

test "runtime policy defaults to deny" {
    const config = Config{
        .library_path = "/explicit/path/secondwind.so",
        .intent_id = 1,
    };
    try std.testing.expect(!config.policy_allowed);
    try std.testing.expect(!config.cache_compatible);
}
