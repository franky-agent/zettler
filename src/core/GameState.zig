//! GameState — top-level game state container.
//!
//! Port of the C# GameState class. Holds all game objects
//! (map, players, buildings, flags, serfs) and the game clock.

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const Map = @import("Map.zig").Map;
const PlayerStates = @import("PlayerState.zig").PlayerStates;
const BuildingStates = @import("BuildingState.zig").BuildingStates;
const FlagStates = @import("FlagState.zig").FlagStates;
const SerfStates = @import("SerfState.zig").SerfStates;
const serialize = @import("serialize");

/// Top-level game state — owns all sub-states.
pub const GameState = struct {
    /// Allocator used for dynamic arrays.
    allocator: std.mem.Allocator,

    // --- Core game state ---
    /// The game map (tile grid).
    map: Map,
    /// Player states (up to 6 players).
    players: PlayerStates = .{},
    /// All buildings on the map.
    buildings: BuildingStates,
    /// All flags on the road network.
    flags: FlagStates,
    /// All serfs (workers) on the map.
    serfs: SerfStates,

    // --- Game clock ---
    /// Current game tick.
    tick: u64 = 0,
    /// Game speed multiplier.
    speed: u8 = 1,

    // --- Game flags ---
    is_paused: bool = false,
    is_game_over: bool = false,

    pub fn init(allocator: std.mem.Allocator, map_w: u16, map_h: u16) !GameState {
        return .{
            .allocator = allocator,
            .map = try Map.initChecked(allocator, map_w, map_h),
            .players = .{},
            .buildings = BuildingStates.init(allocator),
            .flags = FlagStates.init(allocator),
            .serfs = SerfStates.init(allocator),
        };
    }

    pub fn deinit(self: *GameState) void {
        const a = self.allocator;
        self.map.deinit();
        self.buildings.deinit(a);
        self.flags.deinit(a);
        self.serfs.deinit(a);
    }

    /// Advance the game simulation by one tick.
    pub fn tickOnce(self: *GameState) void {
        if (self.is_paused or self.is_game_over) return;
        self.tick += 1;
        // Future: run all game systems here (serf AI, production, etc.)
    }

    /// Run `n` ticks of simulation.
    pub fn tickN(self: *GameState, n: u64) void {
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            self.tickOnce();
        }
    }

    /// Get a reference to the map.
    pub fn getMap(self: *GameState) *Map {
        return &self.map;
    }
};

test "GameState creation" {
    var gs = try GameState.init(std.testing.allocator, 64, 64);
    defer gs.deinit();

    try std.testing.expectEqual(@as(u64, 0), gs.tick);
    try std.testing.expect(!gs.is_paused);
    try std.testing.expect(!gs.is_game_over);
    try std.testing.expectEqual(@as(usize, 64 * 64), gs.map.tileCount());
}

test "GameState tick" {
    var gs = try GameState.init(std.testing.allocator, 32, 32);
    defer gs.deinit();

    gs.tickOnce();
    try std.testing.expectEqual(@as(u64, 1), gs.tick);

    gs.tickN(100);
    try std.testing.expectEqual(@as(u64, 101), gs.tick);
}

test "GameState pause" {
    var gs = try GameState.init(std.testing.allocator, 32, 32);
    defer gs.deinit();

    gs.is_paused = true;
    gs.tickOnce();
    try std.testing.expectEqual(@as(u64, 0), gs.tick);
}
