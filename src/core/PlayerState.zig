//! Player state — represents one of up to 6 players.
//!
//! Each player has resources, serfs, buildings, and military statistics.
//! In the C# version this uses dirty-tracking serialization with [Data] attributes.
//! In Zig we track a dirty flags bitset manually.

const std = @import("std");
const serialize = @import("serialize");
const enums = @import("enums.zig");

const Resource = enums.Resource;
const Building = enums.Building;

/// Number of game ticks between serf reproduction cycles (port of the
/// freeserf `ReproductionReset` constant). When the counter underflows past
/// zero a new serf is spawned (or a knight, if sword+shield are available).
pub const REPRODUCTION_RESET: u16 = 16384;

/// Per-resource distribution priorities for input flows (which processing
/// building gets a scarce resource first). Values mirror the freeserf
/// defaults (range 0..65500, higher = preferred). 0 means "never send".
pub const FoodPriority = struct {
    stone_mine: u16 = 13100,
    coal_mine: u16 = 45850,
    iron_mine: u16 = 45850,
    gold_mine: u16 = 65500,
};

pub const PlanksPriority = struct {
    construction: u16 = 65500,
    boatbuilder: u16 = 3275,
    toolmaker: u16 = 19650,
};

pub const SteelPriority = struct {
    toolmaker: u16 = 45850,
    armory: u16 = 65500,
};

pub const CoalPriority = struct {
    iron_smelter: u16 = 32750,
    gold_smelter: u16 = 65500,
    armory: u16 = 52400,
};

pub const WheatPriority = struct {
    pig_farm: u16 = 65500,
    mill: u16 = 32750,
};

/// Lumber (wood) distribution: sawmill is the primary consumer, boatbuilder
/// secondary. (In the original game wood flows lumberjack→flag→sawmill via
/// transporters; in our simplified stock-centric model the stock pushes wood
/// back out to consumers by these priorities.)
pub const LumberPriority = struct {
    sawmill: u16 = 65500,
    boatbuilder: u16 = 32750,
};

/// Player state data with dirty-tracking.
pub const PlayerState = struct {
    // --- Resources ---
    resources: [@as(usize, Resource.max_count)]u16 = @splat(0),

    // --- Serfs ---
    serf_count: [@intCast(@intFromEnum(enums.SerfType.count))]u16 = @splat(0),

    // --- Buildings ---
    building_count: [@intCast(Building.count)]u16 = @splat(0),
    active_buildings: u32 = 0,

    // --- Military ---
    knight_count: u16 = 0,
    military_strength: u16 = 0,
    territory_count: u16 = 0,

    // --- Score ---
    score_total: u32 = 0,
    score_serf: u16 = 0,
    score_resource: u16 = 0,
    score_military: u16 = 0,
    score_building: u16 = 0,
    score_territory: u16 = 0,
    score_civilisation: u16 = 0,
    score_time: u16 = 0,

    // --- Reproduction / spawning ---
    /// Ticks until the next serf is produced. Decrements each update; when
    /// it underflows past zero a generic serf (or a knight, if armed) is
    /// spawned. Matches the C# `ReproductionCounter`.
    reproduction_counter: u16 = REPRODUCTION_RESET,
    /// Carry-over between updates: how many knights are waiting to be armed.
    knights_to_spawn: u8 = 0,
    /// Rate at which reproduction cycles convert serfs into knights. A
    /// higher value makes knights more frequent (port of `SerfToKnightRate`).
    serf_to_knight_rate: u16 = 0x8000,
    /// Accumulator for the serf→knight conversion decision.
    serf_to_knight_counter: u16 = 0,

    // --- Emergency program ---
    /// True when the emergency program is active: the player has lost (or
    /// never had) a working lumberjack/sawmill/stonecutter chain and is
    /// short on planks/stone, so transports to non-essential buildings are
    /// cancelled.
    emergency_program_active: bool = false,
    /// True once the player has placed at least one stock building (the
    /// reproduction/economy loop only runs for players with a castle/stock).
    has_castle: bool = false,

    // --- Distribution priorities ---
    food: FoodPriority = .{},
    planks: PlanksPriority = .{},
    steel: SteelPriority = .{},
    coal: CoalPriority = .{},
    wheat: WheatPriority = .{},
    lumber: LumberPriority = .{},

    // --- Flags ---
    inventory_dirty: bool = false,
};

/// Array of player states (max 6 players).
pub const PlayerStates = struct {
    players: [6]PlayerState = @splat(PlayerState{}),
    player_count: u8 = 0,

    pub fn get(self: *PlayerStates, index: usize) *PlayerState {
        return &self.players[index];
    }

    pub fn setPlayerCount(self: *PlayerStates, count: u8) void {
        self.player_count = @min(count, 6);
    }
};
