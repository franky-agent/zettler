//! Player — player logic (resource management, AI decisions).
//!
//! Port of the C# Player class (~2,200 lines). Handles:
//! - Resource balancing and distribution
//! - Building construction requests
//! - Serf assignment to buildings
//! - Military unit management
//! - Territory expansion

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const GameState = @import("GameState.zig").GameState;
const PlayerState = @import("PlayerState.zig").PlayerState;
const PlayerStates = @import("PlayerState.zig").PlayerStates;
const BuildingState = @import("BuildingState.zig").BuildingState;
const SerfStateData = @import("SerfState.zig").SerfStateData;
const SerfType = enums.SerfType;
const Resource = enums.Resource;
const Building = enums.Building;
const MapPos = types.MapPos;
const GameObjectIndex = types.GameObjectIndex;

/// Resource distribution strategy.
pub const DistributionStrategy = enum(u2) {
    /// Don't distribute this resource.
    none,
    /// Send resources away from stock to buildings.
    distribute,
    /// Collect resources to stock.
    collect,
};

/// Player update result.
pub const PlayerActionResult = enum(u8) {
    none,
    building_placed,
    serf_assigned,
    resource_distributed,
    serf_spawned,
};

/// Player manager — provides functions for per-player logic.
///
/// This is the per-player logic half of the `updatePlayers` pass. The other
/// half lives in `Game.updatePlayers` (which has access to the global building
/// / flag / serf arrays); the helpers here operate on a single `PlayerState`.
pub const PlayerManager = struct {
    const ConstructionCost = struct { wood: u16, stone: u16, planks: u16 };

    fn constructionCost(building_type: Building) ConstructionCost {
        return switch (building_type) {
            .stonecutter => .{ .wood = 1, .stone = 0, .planks = 1 },
            .lumberjack => .{ .wood = 1, .stone = 0, .planks = 1 },
            .boatbuilder => .{ .wood = 2, .stone = 0, .planks = 2 },
            .sawmill => .{ .wood = 2, .stone = 0, .planks = 2 },
            .forester => .{ .wood = 1, .stone = 0, .planks = 1 },
            .stock => .{ .wood = 3, .stone = 2, .planks = 3 },
            .granite_mine => .{ .wood = 2, .stone = 0, .planks = 2 },
            .coal_mine => .{ .wood = 2, .stone = 0, .planks = 2 },
            .iron_mine => .{ .wood = 2, .stone = 0, .planks = 2 },
            .gold_mine => .{ .wood = 2, .stone = 0, .planks = 2 },
            .iron_smelter => .{ .wood = 2, .stone = 1, .planks = 2 },
            .gold_smelter => .{ .wood = 2, .stone = 1, .planks = 2 },
            .armory => .{ .wood = 2, .stone = 1, .planks = 2 },
            .toolmaker => .{ .wood = 2, .stone = 1, .planks = 2 },
            .bakery => .{ .wood = 1, .stone = 0, .planks = 1 },
            .mill => .{ .wood = 2, .stone = 1, .planks = 2 },
            .slaughterhouse => .{ .wood = 1, .stone = 0, .planks = 1 },
            .pig_farm => .{ .wood = 1, .stone = 0, .planks = 1 },
            .brewery => .{ .wood = 1, .stone = 0, .planks = 1 },
            .winery => .{ .wood = 1, .stone = 0, .planks = 1 },
            .farm => .{ .wood = 2, .stone = 0, .planks = 2 },
            .fisher => .{ .wood = 1, .stone = 0, .planks = 1 },
            .tower => .{ .wood = 2, .stone = 2, .planks = 2 },
            .fortress => .{ .wood = 4, .stone = 4, .planks = 4 },
            .none => .{ .wood = 0, .stone = 0, .planks = 0 },
        };
    }

    /// Check if a player has enough resources to construct a building.
    pub fn canAfford(player: *PlayerState, building_type: Building) bool {
        const cost = constructionCost(building_type);
        return player.resources[@intFromEnum(Resource.wood)] >= cost.wood and
            player.resources[@intFromEnum(Resource.stone)] >= cost.stone and
            player.resources[@intFromEnum(Resource.planks)] >= cost.planks;
    }

    /// Deduct construction cost from player's resources.
    pub fn payFor(player: *PlayerState, building_type: Building) void {
        const cost = constructionCost(building_type);
        player.resources[@intFromEnum(Resource.wood)] -= cost.wood;
        player.resources[@intFromEnum(Resource.stone)] -= cost.stone;
        player.resources[@intFromEnum(Resource.planks)] -= cost.planks;
    }

    /// Count total serfs for a player across all types.
    pub fn totalSerfs(player: *PlayerState) u32 {
        var total: u32 = 0;
        for (player.serf_count) |count| {
            total += count;
        }
        return total;
    }

    /// Get total military strength for a player.
    pub fn militaryStrength(player: *PlayerState) u32 {
        var strength: u32 = 0;
        // Count knights with rank weighting
        for (21..27) |knight_type| {
            const rank = knight_type - 20; // 1-6
            strength += @as(u32, player.serf_count[knight_type]) * rank;
        }
        return strength;
    }

    /// Total count of a building type owned by the player (finished or not).
    pub fn getTotalBuildingCount(player: *PlayerState, building_type: Building) u16 {
        return player.building_count[@intFromEnum(building_type)];
    }

    /// Total number of resources of `res` held in the player's central stock.
    /// (Building-local stocks are tracked separately; this only covers the
    /// `resources[]` array on the player state, i.e. the inventory building.)
    pub fn getResourceAmountInStock(player: *PlayerState, res: Resource) u16 {
        return player.resources[@intFromEnum(res)];
    }

    /// Distribution priority for sending one unit of `res` to a building of
    /// `dest` type. Higher = preferred. 0 = never send. Mirrors the per-resource
    /// priority tables in the C# Player (`FoodPriority`, `PlanksPriority`, ...).
    pub fn distributionPriority(player: *PlayerState, res: Resource, dest: Building) u16 {
        return switch (res) {
            // Food (fish/bread/meat) goes to mines by their food priority.
            .fish, .bread, .meat => switch (dest) {
                .granite_mine => player.food.stone_mine,
                .coal_mine => player.food.coal_mine,
                .iron_mine => player.food.iron_mine,
                .gold_mine => player.food.gold_mine,
                else => 0,
            },
            // Wood (lumber) goes to the sawmill first, then the boatbuilder.
            .wood => switch (dest) {
                .sawmill => player.lumber.sawmill,
                .boatbuilder => player.lumber.boatbuilder,
                else => 0,
            },
            // Planks go to construction first, then boatbuilder/toolmaker.
            .planks => switch (dest) {
                .lumberjack, .sawmill, .stonecutter, .stock, .forester,
                .fisher, .farm, .mill, .bakery, .slaughterhouse, .pig_farm,
                .brewery, .winery, .granite_mine, .coal_mine, .iron_mine,
                .gold_mine, .iron_smelter, .gold_smelter, .armory,
                .tower, .fortress,
                => player.planks.construction,
                .boatbuilder => player.planks.boatbuilder,
                .toolmaker => player.planks.toolmaker,
                else => 0,
            },
            // Steel (iron) goes to armory over toolmaker.
            .iron => switch (dest) {
                .toolmaker => player.steel.toolmaker,
                .armory => player.steel.armory,
                else => 0,
            },
            // Coal goes to gold smelter > armory > iron smelter.
            .coal => switch (dest) {
                .iron_smelter => player.coal.iron_smelter,
                .gold_smelter => player.coal.gold_smelter,
                .armory => player.coal.armory,
                else => 0,
            },
            // Wheat goes to pig farm over mill.
            .grain => switch (dest) {
                .pig_farm => player.wheat.pig_farm,
                .mill => player.wheat.mill,
                .brewery => 0, // barley/wheat split not modelled yet
                else => 0,
            },
            else => 0,
        };
    }

    /// Update the per-tick reproduction counter and spawn serfs/knights.
    /// Returns the kind of spawn that happened this tick (for the Game layer
    /// to actually create the serf entity).
    pub fn updateReproduction(player: *PlayerState, delta: u16) SpawnKind {
        if (!player.has_castle) return .none;

        // Reproduction counter ticks down; when it underflows past zero a
        // reproduction cycle fires and the counter is reset by adding the
        // reset value back (port of the C# `ReproductionCounter += Reset`).
        const old = player.reproduction_counter;
        player.reproduction_counter -%= delta;
        if (player.reproduction_counter <= old) return .none; // no underflow yet

        // A reproduction cycle fired. Reset the counter for the next cycle.
        player.reproduction_counter +%= @import("PlayerState.zig").REPRODUCTION_RESET;

        // Decide serf vs knight.
        player.serf_to_knight_counter +%= player.serf_to_knight_rate;
        if (player.serf_to_knight_counter < player.serf_to_knight_rate) {
            // Not a knight cycle — spawn a generic serf.
            return .serf;
        }

        // Knight cycle: only arm one if swords and shields are in stock.
        if (player.resources[@intFromEnum(Resource.sword)] > 0 and
            player.resources[@intFromEnum(Resource.shield)] > 0)
        {
            if (player.knights_to_spawn < 2) player.knights_to_spawn += 1;
        }
        if (player.knights_to_spawn == 0) return .serf;

        player.knights_to_spawn -= 1;
        player.resources[@intFromEnum(Resource.sword)] -= 1;
        player.resources[@intFromEnum(Resource.shield)] -= 1;
        return .knight;
    }
};

/// What the reproduction cycle wants the Game layer to spawn this tick.
pub const SpawnKind = enum(u8) {
    none,
    /// Spawn a generic transporter/worker serf.
    serf,
    /// Spawn a knight (consumes a sword + shield from the stock).
    knight,
};

test "Player can afford simple building" {
    var player = PlayerState{};
    player.resources[@intFromEnum(Resource.wood)] = 5;
    player.resources[@intFromEnum(Resource.planks)] = 5;

    try std.testing.expect(PlayerManager.canAfford(&player, .lumberjack));
    try std.testing.expect(PlayerManager.canAfford(&player, .sawmill));

    // Not enough stone for tower
    try std.testing.expect(!PlayerManager.canAfford(&player, .tower));
}

test "Player pay for building" {
    var player = PlayerState{};
    player.resources[@intFromEnum(Resource.wood)] = 5;
    player.resources[@intFromEnum(Resource.planks)] = 5;

    PlayerManager.payFor(&player, .lumberjack);
    try std.testing.expectEqual(@as(u16, 4), player.resources[@intFromEnum(Resource.wood)]);
    try std.testing.expectEqual(@as(u16, 4), player.resources[@intFromEnum(Resource.planks)]);
}

test "Player serf count" {
    var player = PlayerState{};
    player.serf_count[@intFromEnum(SerfType.lumberjack)] = 3;
    player.serf_count[@intFromEnum(SerfType.farmer)] = 2;
    player.serf_count[@intFromEnum(SerfType.baker)] = 1;

    try std.testing.expectEqual(@as(u32, 6), PlayerManager.totalSerfs(&player));
}

test "Player resource amount in stock" {
    var player = PlayerState{};
    player.resources[@intFromEnum(Resource.wood)] = 7;
    player.resources[@intFromEnum(Resource.planks)] = 3;

    try std.testing.expectEqual(@as(u16, 7), PlayerManager.getResourceAmountInStock(&player, .wood));
    try std.testing.expectEqual(@as(u16, 3), PlayerManager.getResourceAmountInStock(&player, .planks));
    try std.testing.expectEqual(@as(u16, 0), PlayerManager.getResourceAmountInStock(&player, .stone));
}

test "Player building count getter" {
    var player = PlayerState{};
    player.building_count[@intFromEnum(Building.lumberjack)] = 4;
    player.building_count[@intFromEnum(Building.sawmill)] = 2;

    try std.testing.expectEqual(@as(u16, 4), PlayerManager.getTotalBuildingCount(&player, .lumberjack));
    try std.testing.expectEqual(@as(u16, 2), PlayerManager.getTotalBuildingCount(&player, .sawmill));
    try std.testing.expectEqual(@as(u16, 0), PlayerManager.getTotalBuildingCount(&player, .stock));
}

test "Player distribution priority defaults" {
    var player = PlayerState{};

    // Food: gold mine preferred over stone mine.
    try std.testing.expectEqual(@as(u16, 65500), PlayerManager.distributionPriority(&player, .fish, .gold_mine));
    try std.testing.expectEqual(@as(u16, 13100), PlayerManager.distributionPriority(&player, .bread, .granite_mine));
    // Food doesn't go to non-mines.
    try std.testing.expectEqual(@as(u16, 0), PlayerManager.distributionPriority(&player, .fish, .lumberjack));

    // Planks: construction > toolmaker > boatbuilder.
    try std.testing.expect(player.planks.construction > player.planks.toolmaker);
    try std.testing.expect(player.planks.toolmaker > player.planks.boatbuilder);

    // Steel: armory preferred over toolmaker.
    try std.testing.expect(player.steel.armory > player.steel.toolmaker);

    // Coal: gold smelter > armory > iron smelter.
    try std.testing.expect(player.coal.gold_smelter > player.coal.armory);
    try std.testing.expect(player.coal.armory > player.coal.iron_smelter);

    // Wheat: pig farm preferred over mill.
    try std.testing.expect(player.wheat.pig_farm > player.wheat.mill);
}

test "Player reproduction spawns serfs on timer underflow" {
    var player = PlayerState{};
    player.has_castle = true;
    // Counter at zero — a delta large enough to underflow (wrap past zero)
    // fires one reproduction cycle and resets the counter.
    player.reproduction_counter = 0;

    // First cycle: serf_to_knight_counter wraps without crossing, so a
    // generic serf is requested.
    const spawn = PlayerManager.updateReproduction(&player, 1);
    try std.testing.expectEqual(SpawnKind.serf, spawn);
    // After the cycle fires the counter is reset to ~REPRODUCTION_RESET.
    try std.testing.expect(player.reproduction_counter > 0);
}

test "Player reproduction does nothing without a castle" {
    var player = PlayerState{};
    player.has_castle = false;
    try std.testing.expectEqual(SpawnKind.none, PlayerManager.updateReproduction(&player, 1000));
}

test "Player reproduction spawns a knight when armed" {
    var player = PlayerState{};
    player.has_castle = true;
    player.resources[@intFromEnum(Resource.sword)] = 2;
    player.resources[@intFromEnum(Resource.shield)] = 2;
    // Force a knight cycle: make the serf→knight accumulator high enough
    // that the next wrap crosses the threshold.
    player.serf_to_knight_counter = player.serf_to_knight_rate -% 1;
    player.reproduction_counter = 0;

    const spawn = PlayerManager.updateReproduction(&player, 1);
    try std.testing.expectEqual(SpawnKind.knight, spawn);
    try std.testing.expectEqual(@as(u16, 1), player.resources[@intFromEnum(Resource.sword)]);
    try std.testing.expectEqual(@as(u16, 1), player.resources[@intFromEnum(Resource.shield)]);
}
