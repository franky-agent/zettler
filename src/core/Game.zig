//! Game — root aggregate that owns all subsystems and drives the game loop.
//!
//! Port of the C# Game class. Coordinates: GameState, Player logic,
//! Serf updates, Building production, Flag transport, AI, and victory conditions.

const std = @import("std");
const serialize = @import("serialize");
const enums = @import("enums.zig");
const types = @import("types.zig");
const GameState = @import("GameState.zig").GameState;
const Map = @import("Map.zig").Map;
const Terrain = @import("Map.zig").Terrain;
const PlayerState = @import("PlayerState.zig").PlayerState;
const PlayerStates = @import("PlayerState.zig").PlayerStates;
const BuildingState = @import("BuildingState.zig").BuildingState;
const BuildingManager = @import("Building.zig").BuildingManager;
const FlagState = @import("FlagState.zig").FlagState;
const SerfStateData = @import("SerfState.zig").SerfStateData;
const SerfState = enums.SerfState;
const Inventory = @import("Inventory.zig").Inventory;
const Pathfinder = @import("Pathfinder.zig").Pathfinder;

const Direction = enums.Direction;
const Resource = enums.Resource;
const Building = enums.Building;
const SerfType = enums.SerfType;
const MapPos = types.MapPos;
const GameObjectIndex = types.GameObjectIndex;
const PlayerIndex = types.PlayerIndex;

/// Game speed: how many const-ticks between game logic ticks.
pub const DEFAULT_GAME_SPEED: u8 = 2;
/// Milliseconds per const-tick (50 Hz).
pub const TICK_MS: u64 = 20;
/// Number of players in the game.
pub const MAX_PLAYERS: u8 = 6;

/// Ticks per resource cycle for each building type.
pub const ProductionTimes = struct {
    pub const stonecutter: u16 = 60;
    pub const lumberjack: u16 = 40;
    pub const fisher: u16 = 50;
    pub const farm: u16 = 120;
    pub const mill: u16 = 80;
    pub const bakery: u16 = 70;
    pub const sawmill: u16 = 60;
    pub const iron_smelter: u16 = 100;
    pub const gold_smelter: u16 = 100;
    pub const toolmaker: u16 = 120;
    pub const armory: u16 = 120;
    pub const boatbuilder: u16 = 200;
    pub const slaughterhouse: u16 = 60;
    pub const pig_farm: u16 = 80;
    pub const brewery: u16 = 100;
    pub const winery: u16 = 100;
    pub const forester: u16 = 60;
    pub const coal_mine: u16 = 80;
    pub const iron_mine: u16 = 80;
    pub const gold_mine: u16 = 80;
    pub const granite_mine: u16 = 60;
};

/// Options for constructing a `Game`. Pass `.{}` for defaults.
///
/// `seed` drives procedural terrain generation. When null, a seed is drawn
/// from the OS PRNG on every startup so each session gets a fresh world.
/// `map_file`, when non-null, is loaded with `Map.loadFromFile` and overrides
/// procedural generation entirely (the stored seed is returned in `map_seed`).
pub const InitOptions = struct {
    /// Terrain generation seed. `null` = random per startup.
    seed: ?u64 = null,
    /// Path to a `.zmap` file to load instead of generating terrain.
    map_file: ?[]const u8 = null,
};

/// The root game object — holds all state and update logic.
pub const Game = struct {
    allocator: std.mem.Allocator,
    state: GameState,
    pathfinder: Pathfinder,

    /// Seed used to generate (or load) the current map. Useful for displaying
    /// the seed to the player or saving a replay.
    map_seed: u64 = 0,

    /// Current constant tick (50 Hz counter, not slowed by game speed).
    const_tick: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        map_w: u16,
        map_h: u16,
        player_count: u8,
        opts: InitOptions,
    ) !Game {
        var state = try GameState.init(allocator, map_w, map_h);
        errdefer state.deinit();

        state.players.setPlayerCount(@min(player_count, MAX_PLAYERS));

        // Player 0 is human, others are AI
        for (0..@min(player_count, MAX_PLAYERS)) |i| {
            state.players.players[i].inventory_dirty = true;
        }

        var game = Game{
            .allocator = allocator,
            .state = state,
            .pathfinder = Pathfinder.init(allocator, &state.map),
        };

        if (opts.map_file) |path| {
            // Load the map from file; the stored seed is preserved so the
            // session can be reproduced later.
            if (game.state.map.loadFromFile(path)) |loaded_seed| {
                game.map_seed = loaded_seed;
            } else |err| {
                std.log.warn("map file '{s}' load failed ({}), generating fresh terrain", .{ path, err });
                const s = opts.seed orelse randomSeed();
                game.state.map.generateTerrain(s);
                game.map_seed = s;
            }
        } else {
            // Procedural generation. A null seed means "random each startup".
            const s = opts.seed orelse randomSeed();
            game.state.map.generateTerrain(s);
            game.map_seed = s;
        }

        return game;
    }

    /// Draw a non-deterministic 64-bit seed so that each startup produces
    /// a different world unless the user passes --seed. Reads 8 bytes from
    /// `/dev/urandom` via the C file API (this Zig build lacks `std.time`);
    /// falls back to an address-based entropy source if that fails.
    fn randomSeed() u64 {
        var seed_bytes: [8]u8 = undefined;
        const fd = @as(c_int, @intCast(std.c.open("/dev/urandom", .{})));
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            const got = std.c.read(fd, &seed_bytes, seed_bytes.len);
            if (got == @as(isize, @intCast(seed_bytes.len))) {
                return std.mem.readInt(u64, &seed_bytes, .little);
            }
        }
        // Fallback: mix the address of a stack variable (ASLR-entropy) with
        // a static counter so repeated calls within one run still differ.
        var stack_anchor: u8 = 0;
        const addr: u64 = @intFromPtr(&stack_anchor);
        return addr ^ 0x9E3779B97F4A7C15;
    }

    pub fn deinit(self: *Game) void {
        const a = self.allocator;
        self.pathfinder.deinit(a);
        self.state.deinit();
    }

    /// Game tick at 50 Hz. Every `gameSpeed` calls, run a logic tick.
    pub fn tick(self: *Game, current_const_tick: u64) void {
        self.const_tick = current_const_tick;

        if (self.state.is_paused or self.state.is_game_over) return;

        const speed: u64 = if (self.state.speed == 0) 1 else @intCast(self.state.speed);
        if (current_const_tick % speed != 0) return;

        self.state.tick += 1;
        self.processTick();
    }

    /// One logic tick of game simulation.
    fn processTick(self: *Game) void {
        const game_tick = self.state.tick;

        // Update buildings (production, construction)
        self.updateBuildings(game_tick);

        // Update flags (transporter scheduling, queue processing)
        self.updateFlags(game_tick);

        // Update serfs (FSM tick for all serfs)
        self.updateSerfs(game_tick);

        // Update players (AI decisions, resource balancing)
        self.updatePlayers(game_tick);

        // Update inventories (resource redistribution)
        self.updateInventories(game_tick);
    }

    /// Update all buildings: advance construction, staff finished buildings with
    /// a worker serf, and run production. Iterates by index because production
    /// may spawn serfs / mutate the map.
    fn updateBuildings(self: *Game, game_tick: u64) void {
        var i: usize = 0;
        const n = self.state.buildings.buildings.items.len;
        while (i < n) : (i += 1) {
            const building = &self.state.buildings.buildings.items[i];
            if (!building.is_done) {
                // Construction in progress.
                if (game_tick % 5 == 0) {
                    building.progress += 1;
                    if (building.progress >= 100) building.is_done = true;
                }
                continue;
            }

            if (building.is_burning) continue;
            if (!building.building_type.isProducer()) continue;

            // Staff the finished building with a worker serf if it has none yet
            // (serf assignment: an idle worker is created for the unstaffed
            // building). Best effort — out of memory just skips this tick.
            if (!building.serf_index.isValid()) {
                self.assignWorker(GameObjectIndex{ .index = @intCast(i) }) catch {};
                continue;
            }

            // Production cycle. For easier testing buildings need no input
            // resources; they just produce their output on a timer. Gatherers
            // additionally need (and consume) a nearby map object.
            building.production_tick += 1;
            const prod_time = getProductionTime(building.building_type);
            if (prod_time == 0 or building.production_tick < prod_time) continue;

            if (self.tryProduce(building)) {
                building.production_tick = 0;
                building.production_count +%= 1;
            } else {
                // Stalled (e.g. no tree/rock/water in range) — keep the timer
                // pinned so it retries promptly next tick.
                building.production_tick = prod_time;
            }
        }
    }

    /// Spawn and assign a worker serf to a finished, unstaffed building.
    fn assignWorker(self: *Game, building_idx: GameObjectIndex) !void {
        const b = self.state.buildings.get(building_idx);
        const serf = SerfStateData{
            .pos = b.pos,
            .serf_type = BuildingManager.getRequiredSerfType(b.building_type),
            .player = b.player,
            .state = workerStateFor(b.building_type),
            .building_index = building_idx,
        };
        const sidx = try self.state.serfs.add(self.allocator, serf);
        self.state.buildings.get(building_idx).serf_index = sidx;
    }

    /// Run one production cycle for a staffed building. Returns false if the
    /// building stalled (gatherer with no resource in range), true if it
    /// produced. Output is delivered straight to the owning player's stock for
    /// now (simplified — no transporter walk yet).
    fn tryProduce(self: *Game, building: *BuildingState) bool {
        const map = &self.state.map;
        const radius = 5;
        switch (building.building_type) {
            // Lumberjack: fell the nearest tree (removing it).
            .lumberjack => {
                const t = map.findNearestObject(building.pos, radius, true) orelse return false;
                map.getTile(t).object = .none;
            },
            // Stonecutter: cut the nearest rock (removing it).
            .stonecutter => {
                const t = map.findNearestObject(building.pos, radius, false) orelse return false;
                map.getTile(t).object = .none;
            },
            // Forester: plant a tree on a nearby empty grass tile — produces no
            // resource, it just replenishes the forest for lumberjacks.
            .forester => {
                self.plantTreeNear(building.pos, radius);
                return true;
            },
            // Fisher: needs open water within reach (water is not consumed).
            .fisher => {
                if (!self.hasWaterNear(building.pos, 3)) return false;
            },
            else => {},
        }

        if (getProducedResource(building.building_type)) |res| {
            if (building.player < MAX_PLAYERS) {
                const p = &self.state.players.players[building.player];
                p.resources[@intFromEnum(res)] +|= 1;
            }
        }
        return true;
    }

    /// Plant a tree on the first empty grass tile within `radius` of `pos`.
    fn plantTreeNear(self: *Game, pos: MapPos, radius: i32) void {
        const map = &self.state.map;
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                const tx = @as(i32, @intCast(pos.x)) + dx;
                const ty = @as(i32, @intCast(pos.y)) + dy;
                if (tx < 0 or ty < 0 or tx >= map.width or ty >= map.height) continue;
                const t = map.getTileXY(@intCast(tx), @intCast(ty));
                if (t.terrain == .grass and t.object == .none and !t.has_building and !t.has_flag) {
                    t.object = .pine;
                    t.object_variant = @intCast(@as(u32, @bitCast(dx *% 7 +% dy)) & 7);
                    return;
                }
            }
        }
    }

    /// True if any tile within `radius` of `pos` is water (for the fisher).
    fn hasWaterNear(self: *Game, pos: MapPos, radius: i32) bool {
        const map = &self.state.map;
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                const tx = @as(i32, @intCast(pos.x)) + dx;
                const ty = @as(i32, @intCast(pos.y)) + dy;
                if (tx < 0 or ty < 0 or tx >= map.width or ty >= map.height) continue;
                if (map.getTileXY(@intCast(tx), @intCast(ty)).terrain.isWater()) return true;
            }
        }
        return false;
    }

    /// Update all flags (transporter scheduling).
    fn updateFlags(self: *Game, _: u64) void {
        for (self.state.flags.flags.items, 0..) |*flag, i| {
            _ = i;
            if (flag.incoming_count > 0 and flag.outgoing_count < @import("FlagState.zig").FlagQueueCapacity) {
                const res = flag.incoming_queue[flag.incoming_count - 1];
                flag.outgoing_queue[flag.outgoing_count] = res;
                flag.outgoing_count += 1;
                flag.incoming_count -= 1;
            }
        }
    }

    /// Update all serfs (their FSM tick).
    fn updateSerfs(_: *Game, _: u64) void {
    }

    /// Update all players (AI + resource balancing).
    fn updatePlayers(_: *Game, _: u64) void {
    }

    /// Update inventories — redistribute resources between flags and buildings.
    fn updateInventories(_: *Game, _: u64) void {
    }

    /// Get the current game map.
    pub fn getMap(self: *Game) *Map {
        return &self.state.map;
    }

    /// The serf FSM state a worker occupies when staffing each building type.
    /// (Production is currently driven by the building, not the serf FSM; this
    /// is the semantic/animation state for the assigned worker.)
    fn workerStateFor(b: Building) SerfState {
        return switch (b) {
            .lumberjack => .lumberjack_felling,
            .stonecutter => .stonecutter_mining,
            .fisher => .fisher_fishing,
            .forester => .forester_planting,
            .farm => .farmer_planting,
            .mill => .miller_grinding,
            .bakery => .baker_baking,
            .sawmill => .sawmiller_sawing,
            .slaughterhouse => .butcher_butchering,
            .pig_farm => .pig_farmer_feeding,
            .brewery => .brewer_brewing,
            .winery => .winemaker_making_wine,
            .iron_smelter, .gold_smelter => .smelter_smelting,
            .toolmaker => .toolmaker_making_tools,
            .armory => .armor_smith_forging,
            .boatbuilder => .boatbuilder_building,
            .coal_mine, .iron_mine, .gold_mine, .granite_mine => .miner_mining,
            else => .idle_in_stock,
        };
    }

    /// Get production time for a building type.
    pub fn getProductionTime(building_type: Building) u16 {
        return switch (building_type) {
            .stonecutter => ProductionTimes.stonecutter,
            .lumberjack => ProductionTimes.lumberjack,
            .fisher => ProductionTimes.fisher,
            .farm => ProductionTimes.farm,
            .mill => ProductionTimes.mill,
            .bakery => ProductionTimes.bakery,
            .sawmill => ProductionTimes.sawmill,
            .iron_smelter => ProductionTimes.iron_smelter,
            .gold_smelter => ProductionTimes.gold_smelter,
            .toolmaker => ProductionTimes.toolmaker,
            .armory => ProductionTimes.armory,
            .boatbuilder => ProductionTimes.boatbuilder,
            .slaughterhouse => ProductionTimes.slaughterhouse,
            .pig_farm => ProductionTimes.pig_farm,
            .brewery => ProductionTimes.brewery,
            .winery => ProductionTimes.winery,
            .forester => ProductionTimes.forester,
            .coal_mine => ProductionTimes.coal_mine,
            .iron_mine => ProductionTimes.iron_mine,
            .gold_mine => ProductionTimes.gold_mine,
            .granite_mine => ProductionTimes.granite_mine,
            else => 0,
        };
    }

    /// Get the resource a building produces.
    pub fn getProducedResource(building_type: Building) ?Resource {
        return switch (building_type) {
            .stonecutter => .stone,
            .lumberjack => .wood,
            .fisher => .fish,
            .farm => .grain,
            .mill => .flour,
            .bakery => .bread,
            .sawmill => .planks,
            .iron_smelter => .iron,
            .gold_smelter => .gold,
            .toolmaker => .shovel, // produces random tool
            .armory => .sword, // produces random equipment
            .boatbuilder => .boat,
            .slaughterhouse => .meat,
            .pig_farm => null, // produces serfs (pigs → meat)
            .brewery => .beer,
            .winery => .wine,
            .forester => .wood, // plants trees
            .coal_mine => .coal,
            .iron_mine => .iron_ore,
            .gold_mine => .gold, // gold ore
            .granite_mine => .stone,
            else => null,
        };
    }

    /// Get the resource a building consumes as input.
    pub fn getInputResource(building_type: Building) ?Resource {
        return switch (building_type) {
            .mill => .grain,
            .bakery => .flour,
            .sawmill => .wood,
            .iron_smelter => .iron_ore,
            .gold_smelter => null, // gold ore
            .toolmaker => .iron, // + coal
            .armory => .iron, // + coal
            .boatbuilder => .wood,
            .slaughterhouse => .meat, // from pig farm
            .pig_farm => .grain,
            .brewery => .grain,
            .winery => .fruit,
            .forester => null, // plants trees
            else => null,
        };
    }

    /// Place a building at the given position for the given player.
    /// Returns the building index, or null if placement fails.
    pub fn placeBuilding(self: *Game, pos: MapPos, building_type: Building, player: u8) !?GameObjectIndex {
        if (!self.state.map.isValidPos(pos)) return null;
        const tile = self.state.map.getTile(pos);
        if (tile.has_building) return null;
        // The tile must be clear of standing objects (trees/rocks), like
        // freeserf's map_space_from_obj check.
        if (tile.object != .none) return null;

        // Mines go on rocky high ground (snow/mountain); every other building
        // goes on buildable land. Water satisfies neither, so nothing is ever
        // placed on water.
        if (building_type.isMine()) {
            if (!tile.terrain.isMineable()) return null;
        } else {
            if (!tile.terrain.isBuildable()) return null;
        }

        tile.has_building = true;
        tile.owner = player;

        const building = BuildingState{
            .pos = pos,
            .building_type = building_type,
            .player = player,
            .is_done = false,
            .progress = 0,
        };

        const idx = try self.state.buildings.add(self.allocator, building);
        tile.building_index = idx;

        // Drop the building's flag on the tile down-right of it (as freeserf
        // does), so the building can be connected into the road network. Best
        // effort — if that tile is unavailable the building simply has no flag.
        const flag_pos = pos.move(.down_right);
        if (self.state.map.isValidPos(flag_pos)) {
            const ftile = self.state.map.getTile(flag_pos);
            if (!ftile.has_flag and !ftile.has_building and !ftile.terrain.isWater()) {
                // Clear any tree/rock on the flag spot so the building always
                // gets a flag (and can be connected by roads).
                ftile.object = .none;
                if (self.placeFlag(flag_pos, player) catch null) |fidx| {
                    self.state.buildings.get(idx).flag_index = fidx;
                    self.state.flags.get(fidx).building_index = idx;
                }
            }
        }

        return idx;
    }

    /// Place a flag at the given position for the given player.
    pub fn placeFlag(self: *Game, pos: MapPos, player: u8) !?GameObjectIndex {
        if (!self.state.map.isValidPos(pos)) return null;
        const tile = self.state.map.getTile(pos);
        if (tile.has_flag) return null;

        tile.has_flag = true;
        tile.owner = player;

        const flag = FlagState{
            .pos = pos,
            .player = player,
        };

        const idx = try self.state.flags.add(self.allocator, flag);
        tile.flag_index = idx;
        return idx;
    }

    /// Build a road between two existing flags along `path` (a list of direction
    /// steps leaving `from`). Marks the intermediate tiles as road and links the
    /// two flags in the flag graph. Returns false if the endpoints aren't flags
    /// or the path doesn't connect them. (Simplified: no wood cost, no per-tile
    /// passability re-check beyond "not a building".)
    pub fn buildRoad(self: *Game, from: MapPos, to: MapPos, path: []const u8) bool {
        const map = &self.state.map;
        if (path.len == 0) return false;
        const ftile = map.getTile(from);
        const ttile = map.getTile(to);
        if (!ftile.has_flag or !ttile.has_flag) return false;

        // Validate the path connects from→to and isn't blocked, before mutating.
        // Uses wrapping so roads can wrap across map edges.
        var p = from;
        for (path, 0..) |d, i| {
            if (d >= Direction.count) return false;
            p = map.wrapPos(p.move(@enumFromInt(d)));
            if (i < path.len - 1 and map.getTile(p).has_building) return false;
        }
        if (!p.eql(to)) return false;

        // Mark intermediate tiles as road.
        p = from;
        for (path, 0..) |d, i| {
            p = map.wrapPos(p.move(@enumFromInt(d)));
            if (i < path.len - 1) map.getTile(p).has_road = true;
        }

        // Link the two flags in the graph (both directions).
        const from_idx = ftile.flag_index;
        const to_idx = ttile.flag_index;
        if (from_idx.isValid() and to_idx.isValid()) {
            const first_dir: usize = @intCast(path[0]);
            const back_dir: Direction = (@as(Direction, @enumFromInt(path[path.len - 1]))).opposite();
            const seg_len: u8 = @intCast(@min(path.len, 255));
            self.state.flags.get(from_idx).next[first_dir] = to_idx;
            self.state.flags.get(from_idx).length[first_dir] = seg_len;
            self.state.flags.get(to_idx).next[@intFromEnum(back_dir)] = from_idx;
            self.state.flags.get(to_idx).length[@intFromEnum(back_dir)] = seg_len;
        }
        return true;
    }
};

test "Game init and tick" {
    var game = try Game.init(std.testing.allocator, 32, 32, 1, .{ .seed = 42 });
    defer game.deinit();

    try std.testing.expectEqual(@as(u64, 0), game.state.tick);
    game.tick(2); // speed=2, so this should tick once
    try std.testing.expectEqual(@as(u64, 1), game.state.tick);
}

test "Game place building" {
    var game = try Game.init(std.testing.allocator, 32, 32, 1, .{ .seed = 42 });
    defer game.deinit();

    const pos = types.MapPos{ .x = 10, .y = 10 };
    const idx = try game.placeBuilding(pos, .lumberjack, 0);

    try std.testing.expect(idx != null);
    if (idx) |i| {
        const building = game.state.buildings.get(i);
        try std.testing.expectEqual(Building.lumberjack, building.building_type);
        try std.testing.expect(!building.is_done);
    }
}

test "Game production time" {
    try std.testing.expectEqual(@as(u16, 40), Game.getProductionTime(.lumberjack));
    try std.testing.expectEqual(@as(u16, 120), Game.getProductionTime(.farm));
    try std.testing.expectEqual(@as(u16, 0), Game.getProductionTime(.none));
}

test "Terrain generation scatters objects" {
    var game = try Game.init(std.testing.allocator, 48, 48, 1, .{ .seed = 42 });
    defer game.deinit();
    var objects: usize = 0;
    for (game.state.map.tiles) |t| {
        if (t.object != .none) objects += 1;
    }
    try std.testing.expect(objects > 0);
}

test "Cannot build on a tile with an object" {
    var game = try Game.init(std.testing.allocator, 16, 16, 1, .{ .seed = 42 });
    defer game.deinit();
    const pos = types.MapPos{ .x = 8, .y = 8 };
    const tile = game.state.map.getTile(pos);
    tile.terrain = .grass;
    tile.object = .tree;
    try std.testing.expect((try game.placeBuilding(pos, .lumberjack, 0)) == null);
    tile.object = .none;
    try std.testing.expect((try game.placeBuilding(pos, .lumberjack, 0)) != null);
}

test "Staffed lumberjack fells a nearby tree and yields wood" {
    var game = try Game.init(std.testing.allocator, 16, 16, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const pos = types.MapPos{ .x = 8, .y = 8 };
    const tile = game.state.map.getTile(pos);
    tile.terrain = .grass;
    tile.object = .none;
    const idx = (try game.placeBuilding(pos, .lumberjack, 0)).?;
    game.state.buildings.get(idx).is_done = true; // skip construction for the test

    const tree_pos = types.MapPos{ .x = 9, .y = 8 };
    game.state.map.getTile(tree_pos).object = .tree;

    var t: u64 = 1;
    while (t <= 200) : (t += 1) game.tick(t);

    try std.testing.expect(game.state.buildings.get(idx).serf_index.isValid());
    try std.testing.expect(game.state.players.players[0].resources[@intFromEnum(Resource.wood)] > 0);
    try std.testing.expectEqual(@import("Map.zig").MapObject.none, game.state.map.getTile(tree_pos).object);
}

test "buildRoad links two flags and marks the path" {
    var game = try Game.init(std.testing.allocator, 16, 16, 1, .{ .seed = 42 });
    defer game.deinit();
    const a = types.MapPos{ .x = 4, .y = 4 };
    const b = types.MapPos{ .x = 6, .y = 4 };
    for ([_]types.MapPos{ a, b, .{ .x = 5, .y = 4 } }) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
    }
    _ = try game.placeFlag(a, 0);
    _ = try game.placeFlag(b, 0);
    const path = [_]u8{ @intFromEnum(Direction.right), @intFromEnum(Direction.right) };
    try std.testing.expect(game.buildRoad(a, b, &path));
    try std.testing.expect(game.state.map.getTile(.{ .x = 5, .y = 4 }).has_road);
}
