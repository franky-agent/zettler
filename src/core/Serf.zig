//! Serf — serf finite state machine and behavior logic.
//!
//! Port of the C# Serf class (~9,659 lines). This is the heart of the game.
//! Serfs are the worker units that perform all game actions:
//! walking, transporting resources, mining, farming, building, fighting, etc.
//!
//! The FSM uses a large switch statement over ~80 states.
//! Each state variant in SerfState has a corresponding update method.
//!
//! Phase 2 implementation: core walking, transport, and production states.

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const GameState = @import("GameState.zig").GameState;
const Map = @import("Map.zig").Map;
const SerfStateData = @import("SerfState.zig").SerfStateData;
const Pathfinder = @import("Pathfinder.zig").Pathfinder;
const Path = @import("Pathfinder.zig").Path;

const Direction = enums.Direction;
const Resource = enums.Resource;
const Building = enums.Building;
const SerfType = enums.SerfType;
const SerfStateEnum = enums.SerfState;
const MapPos = types.MapPos;
const GameObjectIndex = types.GameObjectIndex;

/// Maximum serfs per player.
pub const MAX_SERFS_PER_PLAYER: u16 = 1024;

/// Serf update result — what happened during this tick.
pub const SerfActionResult = enum(u8) {
    none,
    moved,
    delivered_resource,
    picked_up_resource,
    started_construction,
    completed_construction,
    started_production,
    completed_production,
    died,
};

/// Serf manager — provides update functions for serf state machines.
/// In the C# version these are methods on the Serf class.
/// In Zig we keep the data in SerfStateData and the logic in standalone functions.
pub const Serf = struct {
    /// Main update function — dispatches to the correct handler for
    /// the serf's current state. Returns what action was performed.
    pub fn update(serf: *SerfStateData, state: *GameState, tick: u64) SerfActionResult {
        _ = tick;
        switch (serf.state) {
            .idle_in_stock => return updateIdleInStock(serf, state),
            .waiting_at_flag => return updateWaitingAtFlag(serf, state),
            .walking_on_road => return updateWalkingOnRoad(serf, state),
            .walking_on_land => return updateWalkingOnLand(serf, state),
            .entering_building => return updateEnteringBuilding(serf, state),
            .leaving_building => return updateLeavingBuilding(serf, state),
            .leaving_building_2 => return updateLeavingBuilding2(serf, state),
            .transporting => return updateTransporting(serf, state),
            .transporting_on_road => return updateTransportingOnRoad(serf, state),
            .delivering_to_building => return updateDeliveringToBuilding(serf, state),
            .delivering_to_flag => return updateDeliveringToFlag(serf, state),
            .delivering_from_building => return updateDeliveringFromBuilding(serf, state),
            .picking_up_from_flag => return updatePickingUpFromFlag(serf, state),
            .delivering_to_stock => return updateDeliveringToStock(serf, state),
            .picking_up_from_stock => return updatePickingUpFromStock(serf, state),
            // Production states
            .lumberjack_felling => return updateLumberjackFelling(serf, state),
            .fisher_fishing => return updateFisherFishing(serf, state),
            .farmer_planting => return updateFarmerPlanting(serf, state),
            .farmer_harvesting => return updateFarmerHarvesting(serf, state),
            .forester_planting => return updateForesterPlanting(serf, state),
            .miner_mining => return updateMinerMining(serf, state),
            .stonecutter_mining => return updateStonecutterMining(serf, state),
            .miller_grinding => return updateMillerGrinding(serf, state),
            .baker_baking => return updateBakerBaking(serf, state),
            .butcher_butchering => return updateButcherButchering(serf, state),
            .brewer_brewing => return updateBrewerBrewing(serf, state),
            // Builder states
            .builder_walking => return updateBuilderWalking(serf, state),
            .builder_constructing => return updateBuilderConstructing(serf, state),
            // Military states (stubs)
            .defending => return updateDefending(serf, state),
            .attacking => return updateAttacking(serf, state),
            .fighting => return updateFighting(serf, state),
            .fleeing => return updateFleeing(serf, state),
            // Geologist
            .geologist_searching => return updateGeologistSearching(serf, state),
            // Misc
            .wandering => return updateWandering(serf, state),
            .sleeping => return updateSleeping(serf, state),
            else => {
                // Unimplemented states — do nothing for now
                serf.tick += 1;
                return .none;
            },
        }
    }

    // ==== IDLE / WAITING STATES ====

    /// Serf is idle in the stock (warehouse/castle).
    /// Wait until assigned to a building or task.
    fn updateIdleInStock(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        // Future: check if there is work to assign
        return .none;
    }

    /// Serf is waiting at a flag for resources or instructions.
    fn updateWaitingAtFlag(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        // Future: check outgoing queue at flag, pick up resources
        return .none;
    }

    // ==== MOVEMENT STATES ====

    /// Serf is walking on a road.
    fn updateWalkingOnRoad(serf: *SerfStateData, _: *GameState) SerfActionResult {
        if (serf.road_progress < 255) {
            serf.road_progress += 16;
            if (serf.road_progress >= 255) {
                serf.road_progress = 0;
                serf.road_index += 1;
                // Check if we reached destination
                if (serf.road_index >= serf.path_length) {
                    serf.state = .waiting_at_flag;
                    return .moved;
                }
            }
        }
        return .moved;
    }

    /// Serf is walking on land (not on a road).
    fn updateWalkingOnLand(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        // Move one step towards destination
        if (serf.path_index < serf.path_length) {
            const dir_int = serf.path[serf.path_index];
            const dir: Direction = @enumFromInt(dir_int);
            serf.pos = serf.pos.move(dir);
            serf.path_index += 1;
            return .moved;
        }
        // Reached destination
        serf.state = .idle_in_stock;
        return .moved;
    }

    /// Serf is entering a building.
    fn updateEnteringBuilding(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 10) {
            serf.state = .idle_in_stock;
        }
        return .none;
    }

    /// Serf is leaving a building (phase 1).
    fn updateLeavingBuilding(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 5) {
            serf.state = .leaving_building_2;
        }
        return .none;
    }

    /// Serf is leaving a building (phase 2).
    fn updateLeavingBuilding2(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 5) {
            serf.state = .idle_in_stock;
        }
        return .none;
    }

    // ==== TRANSPORT STATES ====

    /// Serf is transporting resources between locations.
    fn updateTransporting(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 30) {
            serf.state = .transporting_on_road;
        }
        return .none;
    }

    /// Serf is transporting resources on a road.
    fn updateTransportingOnRoad(serf: *SerfStateData, state: *GameState) SerfActionResult {
        return updateWalkingOnRoad(serf, state);
    }

    /// Serf is delivering resources to a building.
    fn updateDeliveringToBuilding(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 15) {
            serf.state = .idle_in_stock;
            return .delivered_resource;
        }
        return .none;
    }

    /// Serf is delivering resources to a flag.
    fn updateDeliveringToFlag(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 10) {
            serf.state = .waiting_at_flag;
            return .delivered_resource;
        }
        return .none;
    }

    /// Serf is delivering resources from a building to the outside.
    fn updateDeliveringFromBuilding(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 10) {
            serf.state = .delivering_to_flag;
            return .delivered_resource;
        }
        return .none;
    }

    /// Serf is picking up resources from a flag.
    fn updatePickingUpFromFlag(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 5) {
            serf.state = .transporting;
            return .picked_up_resource;
        }
        return .none;
    }

    /// Serf delivering resources to the stock (warehouse).
    fn updateDeliveringToStock(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 20) {
            serf.state = .idle_in_stock;
            return .delivered_resource;
        }
        return .none;
    }

    /// Serf picking up resources from stock.
    fn updatePickingUpFromStock(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 10) {
            serf.state = .transporting;
            return .picked_up_resource;
        }
        return .none;
    }

    // ==== PRODUCTION STATES ====

    /// Lumberjack is felling a tree.
    fn updateLumberjackFelling(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 40) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            // Add wood to player's inventory
            if (serf.player < 6) {
                state.players.players[serf.player].resources[@intFromEnum(Resource.wood)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Fisher is fishing.
    fn updateFisherFishing(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 50) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                state.players.players[serf.player].resources[@intFromEnum(Resource.fish)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Farmer is planting.
    fn updateFarmerPlanting(serf: *SerfStateData, _: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 60) {
            serf.tick = 0;
            serf.state = .farmer_harvesting;
            return .none;
        }
        return .none;
    }

    /// Farmer is harvesting.
    fn updateFarmerHarvesting(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 60) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                state.players.players[serf.player].resources[@intFromEnum(Resource.grain)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Forester is planting trees.
    fn updateForesterPlanting(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick >= 60) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            return .completed_production;
        }
        return .none;
    }

    /// Miner is mining ore/coal.
    fn updateMinerMining(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 80) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            // Add mined resource to player's inventory based on building type
            if (serf.building_index.isValid() and serf.player < 6) {
                const building = state.buildings.get(serf.building_index);
                const res = switch (building.building_type) {
                    .coal_mine => Resource.coal,
                    .iron_mine => Resource.iron_ore,
                    .gold_mine => Resource.gold,
                    .granite_mine => Resource.stone,
                    else => Resource.stone,
                };
                state.players.players[serf.player].resources[@intFromEnum(res)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Stonecutter is mining stone.
    fn updateStonecutterMining(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 60) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                state.players.players[serf.player].resources[@intFromEnum(Resource.stone)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Miller is grinding grain into flour.
    fn updateMillerGrinding(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 80) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                // Consume grain, produce flour
                if (state.players.players[serf.player].resources[@intFromEnum(Resource.grain)] > 0) {
                    state.players.players[serf.player].resources[@intFromEnum(Resource.grain)] -= 1;
                    state.players.players[serf.player].resources[@intFromEnum(Resource.flour)] += 1;
                }
            }
            return .completed_production;
        }
        return .none;
    }

    /// Baker is baking bread.
    fn updateBakerBaking(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 70) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                if (state.players.players[serf.player].resources[@intFromEnum(Resource.flour)] > 0) {
                    state.players.players[serf.player].resources[@intFromEnum(Resource.flour)] -= 1;
                    state.players.players[serf.player].resources[@intFromEnum(Resource.bread)] += 1;
                }
            }
            return .completed_production;
        }
        return .none;
    }

    /// Butcher is making meat.
    fn updateButcherButchering(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 60) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                state.players.players[serf.player].resources[@intFromEnum(Resource.meat)] += 1;
            }
            return .completed_production;
        }
        return .none;
    }

    /// Brewer is brewing beer.
    fn updateBrewerBrewing(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 100) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            if (serf.player < 6) {
                if (state.players.players[serf.player].resources[@intFromEnum(Resource.grain)] > 0) {
                    state.players.players[serf.player].resources[@intFromEnum(Resource.grain)] -= 1;
                    state.players.players[serf.player].resources[@intFromEnum(Resource.beer)] += 1;
                }
            }
            return .completed_production;
        }
        return .none;
    }

    // ==== BUILDER STATES ====

    /// Builder is walking to the construction site.
    fn updateBuilderWalking(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick > 20) {
            serf.state = .builder_constructing;
            serf.tick = 0;
        }
        return .none;
    }

    /// Builder is constructing a building.
    fn updateBuilderConstructing(serf: *SerfStateData, state: *GameState) SerfActionResult {
        serf.tick += 1;
        if (serf.tick >= 30) {
            serf.tick = 0;
            // Advance building construction
            if (serf.building_index.isValid()) {
                const building = state.buildings.get(serf.building_index);
                if (!building.is_done) {
                    building.progress += 5;
                    if (building.progress >= 100) {
                        building.is_done = true;
                        serf.state = .idle_in_stock;
                        return .completed_construction;
                    }
                }
            }
        }
        return .none;
    }

    // ==== MILITARY STATES (stubs) ====

    fn updateDefending(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }

    fn updateAttacking(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }

    fn updateFighting(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }

    fn updateFleeing(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }

    // ==== GEOLOGIST ====

    fn updateGeologistSearching(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        if (serf.tick >= 100) {
            serf.tick = 0;
            serf.state = .idle_in_stock;
            return .completed_production;
        }
        return .none;
    }

    // ==== MISC ====

    fn updateWandering(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }

    fn updateSleeping(serf: *SerfStateData, state: *GameState) SerfActionResult {
        _ = state;
        serf.tick += 1;
        return .none;
    }
};

test "Serf idle in stock" {
    var state = try GameState.init(std.testing.allocator, 32, 32);
    defer state.deinit();

    var serf = SerfStateData{
        .state = .idle_in_stock,
        .player = 0,
    };

    const result = Serf.update(&serf, &state, 0);
    try std.testing.expectEqual(SerfActionResult.none, result);
}

test "Serf lumberjack felling produces wood" {
    var state = try GameState.init(std.testing.allocator, 32, 32);
    defer state.deinit();
    state.players.player_count = 1;

    var serf = SerfStateData{
        .state = .lumberjack_felling,
        .player = 0,
        .tick = 39, // one tick away from completion
    };

    const result = Serf.update(&serf, &state, 0);
    try std.testing.expectEqual(SerfActionResult.completed_production, result);
    try std.testing.expectEqual(@as(u16, 1), state.players.players[0].resources[@intFromEnum(Resource.wood)]);
}

test "Serf walking on land" {
    var state = try GameState.init(std.testing.allocator, 32, 32);
    defer state.deinit();

    var serf = SerfStateData{
        .state = .walking_on_land,
        .pos = MapPos{ .x = 10, .y = 10 },
        .path = [_]u8{ @intFromEnum(Direction.right), @intFromEnum(Direction.down_right), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .path_length = 2,
        .path_index = 0,
    };

    const result = Serf.update(&serf, &state, 0);
    try std.testing.expectEqual(SerfActionResult.moved, result);
    try std.testing.expectEqual(@as(u16, 11), serf.pos.x);
    try std.testing.expectEqual(@as(u16, 10), serf.pos.y);
    try std.testing.expectEqual(@as(u8, 1), serf.path_index);
}
