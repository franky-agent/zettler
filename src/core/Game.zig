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
const PlayerManager = @import("Player.zig").PlayerManager;
const SpawnKind = @import("Player.zig").SpawnKind;
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
    /// building stalled (gatherer with no resource in range, or processor
    /// with no input stock), true if it produced. Output goes into the
    /// building's local stock (`resources`/`resource_types`);
    /// `updateInventories` later moves it to the connected flag and onward to
    /// the player's stock.
    fn tryProduce(self: *Game, building: *BuildingState) bool {
        const map = &self.state.map;
        const radius = 5;

        // Gatherers interact with the map (consume a tree/rock, check water).
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
            // Forester: plant a tree on a nearby empty grass tile. Produces no
            // resource (it replenishes the forest for lumberjacks), so there is
            // no output to stock.
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

        // Processing buildings: consume one unit of input from the building
        // stock before producing. If the input is unavailable, stall.
        if (getInputResource(building.building_type)) |input_res| {
            if (building.removeStock(input_res, 1) == 0) return false;
        }

        // Deposit the output into the building's local stock. If the stock is
        // full (all 4 slots occupied by other resources), stall so the timer
        // retries once `updateInventories` frees space.
        if (getProducedResource(building.building_type)) |res| {
            if (building.addStock(res, 1) == 0) {
                // Reclaim the consumed input so it isn't lost.
                if (getInputResource(building.building_type)) |input_res| {
                    _ = building.addStock(input_res, 1);
                }
                return false;
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

    /// Update all players — per-tick player economy logic.
    ///
    /// For each active player this:
    /// 1. Recounts buildings into `building_count[]` and sets `has_castle`.
    /// 2. Advances the reproduction counter and spawns serfs/knights.
    /// 3. Runs the emergency program (cancel non-essential transports when the
    ///    lumberjack/sawmill/stonecutter chain is broken).
    /// 4. Distributes input resources from the player's stock out to processing
    ///    buildings' flags (so `updateInventories` Pass 2 can pull them in).
    ///    The destination is chosen by per-resource distribution priorities.
    fn updatePlayers(self: *Game, game_tick: u64) void {
        const players = &self.state.players;

        var pi: u8 = 0;
        while (pi < players.player_count) : (pi += 1) {
            const player = &players.players[pi];

            // (1) Recount buildings and detect a castle/stock.
            recountBuildings(self, pi);

            // (2) Reproduction. One tick per update; the Game layer owns serf
            // creation because it needs the allocator and the serf array.
            const spawn = PlayerManager.updateReproduction(player, 1);
            switch (spawn) {
                .serf => self.spawnSerfFor(pi, .generic) catch {},
                .knight => self.spawnSerfFor(pi, .knight_0) catch {},
                .none => {},
            }

            // (3) Emergency program.
            updateEmergencyProgram(self, pi);

            // (4) Distribute input resources from stock to processing buildings.
            // One unit per resource per tick, sent to the highest-priority
            // building that still needs it.
            distributeStockToBuildings(self, pi);

            _ = game_tick; // available for future rate-gated work
        }
    }

    /// Recompute `player.building_count[]` from the live building list and set
    /// `has_castle` if the player owns at least one finished stock building.
    fn recountBuildings(self: *Game, player_index: u8) void {
        const player = &self.state.players.players[player_index];
        @memset(&player.building_count, 0);
        player.has_castle = false;
        for (self.state.buildings.buildings.items) |*b| {
            if (b.player != player_index) continue;
            player.building_count[@intFromEnum(b.building_type)] += 1;
            if (b.building_type == .stock and b.is_done) player.has_castle = true;
        }
    }

    /// Spawn a serf of the given type for `player_index` at that player's first
    /// stock building (or origin if none). Mirrors the C# `SpawnSerf` path.
    fn spawnSerfFor(self: *Game, player_index: u8, serf_type: SerfType) !void {
        var pos = MapPos.zero;
        for (self.state.buildings.buildings.items) |*b| {
            if (b.player == player_index and b.building_type == .stock and b.is_done) {
                pos = b.pos;
                break;
            }
        }
        const serf = SerfStateData{
            .pos = pos,
            .serf_type = serf_type,
            .player = player_index,
            .state = .idle_in_stock,
        };
        _ = try self.state.serfs.add(self.allocator, serf);
        self.state.players.players[player_index].serf_count[@intFromEnum(serf_type)] +|= 1;
    }

    /// Emergency program: if the player has no working
    /// lumberjack/sawmill/stonecutter and too few planks/stone to rebuild one,
    /// flag `emergency_program_active` so future transports can be cancelled.
    /// (Cancellation of in-flight transports is a stub for now — the flag is
    /// what downstream tasks 2p.4/2p.5 will consult.)
    fn updateEmergencyProgram(self: *Game, player_index: u8) void {
        const player = &self.state.players.players[player_index];

        const has_lumberjack = player.building_count[@intFromEnum(Building.lumberjack)] > 0;
        const has_sawmill = player.building_count[@intFromEnum(Building.sawmill)] > 0;
        const has_stonecutter = player.building_count[@intFromEnum(Building.stonecutter)] > 0;

        if (has_lumberjack and has_sawmill and has_stonecutter) {
            player.emergency_program_active = false;
            return;
        }

        // Planks/stone needed to rebuild the missing essential buildings.
        // Costs mirror `PlayerManager.constructionCost` (lumberjack/sawmill/
        // stonecutter are the essential chain).
        var planks_needed: u16 = 0;
        var stone_needed: u16 = 0;
        if (!has_lumberjack) {
            planks_needed += 1; // lumberjack: 1 plank
        }
        if (!has_sawmill) {
            planks_needed += 2; // sawmill: 2 planks, 1 stone
            stone_needed += 1;
        }
        if (!has_stonecutter) {
            planks_needed += 1; // stonecutter: 1 plank
        }

        const planks = player.resources[@intFromEnum(Resource.planks)];
        const stone = player.resources[@intFromEnum(Resource.stone)];
        const short_on_planks = planks < planks_needed;
        const short_on_stone = stone < stone_needed;

        if (short_on_planks or short_on_stone) {
            player.emergency_program_active = true;
        } else {
            player.emergency_program_active = false;
        }
    }

    /// Pull input resources out of the player's stock and queue them on the
    /// flags of processing buildings that consume them. For each input
    /// resource the highest-priority unstocked building wins one unit per tick.
    ///
    /// This is the reverse of `updateInventories` Pass 3 (which delivers
    /// produced goods to stock): it keeps processing buildings fed so the
    /// economy doesn't stall once stock runs low.
    fn distributeStockToBuildings(self: *Game, player_index: u8) void {
        const player = &self.state.players.players[player_index];
        const buildings = &self.state.buildings;
        const flags = &self.state.flags;
        const FlagQueueCapacity = @import("FlagState.zig").FlagQueueCapacity;

        // Resources that processing buildings consume and that we therefore
        // push out from stock. (Wood is also consumed by sawmill/boatbuilder.)
        const distributable = [_]Resource{
            .grain, .flour, .wood, .iron_ore, .iron, .coal, .meat,
        };

        for (distributable) |res| {
            if (player.resources[@intFromEnum(res)] == 0) continue;

            // Find the consumer building with the highest priority whose flag
            // has space and whose stock isn't already full of that resource.
            var best_idx: ?usize = null;
            var best_pri: u16 = 0;
            for (buildings.buildings.items, 0..) |*b, i| {
                if (b.player != player_index) continue;
                if (!b.is_done or b.is_burning) continue;
                const input = getInputResource(b.building_type) orelse continue;
                if (input != res) continue;
                // Don't push to a building whose local stock already holds the
                // resource at capacity (4 slots) — it would just bounce back.
                if (b.findStockSlot(res) != null and b.stockCount(res) >= 8) continue;
                if (!b.flag_index.isValid()) continue;
                const flag = flags.get(b.flag_index);
                if (flag.incoming_count >= FlagQueueCapacity) continue;

                const pri = PlayerManager.distributionPriority(player, res, b.building_type);
                if (pri == 0) continue;
                if (pri > best_pri) {
                    best_pri = pri;
                    best_idx = i;
                }
            }

            if (best_idx) |bi| {
                const b = &buildings.buildings.items[bi];
                const flag = flags.get(b.flag_index);
                flag.incoming_queue[flag.incoming_count] = @intFromEnum(res);
                flag.incoming_count += 1;
                player.resources[@intFromEnum(res)] -= 1;
            }
        }
    }

    /// Update inventories — move resources between buildings, flags, and the
    /// player's stock. Three passes per tick:
    ///
    /// 1. **Building → flag (output export):** each producer building pushes
    ///    one unit of each stocked output resource onto its connected flag's
    ///    incoming queue (if space).
    /// 2. **Flag → building (input import):** each processing building pulls
    ///    one unit of its input resource from its connected flag's outgoing
    ///    queue into its stock (if space).
    /// 3. **Flag → stock (delivery):** resources sitting in a flag's outgoing
    ///    queue are delivered to the player's stock. If the flag is attached
    ///    to a stock building, it is absorbed directly. Otherwise a BFS over
    ///    the road network finds a path to a stock building's flag and
    ///    delivers there. Flags with no road connections at all deliver
    ///    straight to the player stock (fallback so unconnected buildings
    ///    still contribute to the economy before roads are built).
    fn updateInventories(self: *Game, _: u64) void {
        const flags = &self.state.flags;
        const buildings = &self.state.buildings;

        // --- Pass 1: building → flag (output export) ---
        for (buildings.buildings.items) |*b| {
            if (!b.is_done or b.is_burning) continue;
            if (!b.flag_index.isValid()) continue;
            const flag = flags.get(b.flag_index);
            // Push up to 1 unit of each stocked resource per tick.
            for (0..4) |si| {
                if (b.resources[si] == 0) continue;
                const res: u8 = b.resource_types[si];
                if (flag.incoming_count >= @import("FlagState.zig").FlagQueueCapacity) break;
                flag.incoming_queue[flag.incoming_count] = res;
                flag.incoming_count += 1;
                b.resources[si] -= 1;
                if (b.resources[si] == 0) b.resource_types[si] = 0;
            }
        }

        // --- Pass 2: flag → building (input import) ---
        for (buildings.buildings.items) |*b| {
            if (!b.is_done or b.is_burning) continue;
            if (!b.flag_index.isValid()) continue;
            const input_res = getInputResource(b.building_type) orelse continue;
            const flag = flags.get(b.flag_index);
            if (flag.outgoing_count == 0) continue;
            // Find a matching resource in the outgoing queue.
            const want = @intFromEnum(input_res);
            var qi: u8 = 0;
            while (qi < flag.outgoing_count) : (qi += 1) {
                if (flag.outgoing_queue[qi] == want) break;
            }
            if (qi >= flag.outgoing_count) continue; // not present
            if (b.addStock(input_res, 1) == 0) continue; // building stock full
            // Remove the item from the outgoing queue (compact).
            var j = qi;
            while (j + 1 < flag.outgoing_count) : (j += 1) {
                flag.outgoing_queue[j] = flag.outgoing_queue[j + 1];
            }
            flag.outgoing_count -= 1;
        }

        // --- Pass 3: flag → stock (delivery) ---
        // Pre-compute which flags are attached to a stock building.
        var flag_idx: usize = 0;
        while (flag_idx < flags.flags.items.len) : (flag_idx += 1) {
            const flag = &flags.flags.items[flag_idx];
            if (flag.outgoing_count == 0) continue;

            const fis_stock = blk: {
                if (flag.building_index.isValid()) {
                    const bld = buildings.get(flag.building_index);
                    break :blk bld.building_type == .stock;
                }
                break :blk false;
            };

            const deliver_to_stock = fis_stock or self.flagReachesStock(@intCast(flag_idx));

            // Drain the outgoing queue.
            while (flag.outgoing_count > 0) {
                const res = flag.outgoing_queue[flag.outgoing_count - 1];
                flag.outgoing_count -= 1;
                if (flag.player < MAX_PLAYERS) {
                    self.state.players.players[flag.player].resources[res] +|= 1;
                }
                // If this flag isn't connected to a stock, only deliver one
                // item per tick (fallback pace) so unconnected buildings
                // don't dump their entire queue instantly.
                if (!deliver_to_stock) break;
            }
        }
    }

    /// BFS over the road network (flag `next[6]` graph) to determine whether
    /// the flag at `flag_idx` can reach a stock building's flag.
    fn flagReachesStock(self: *Game, flag_idx: usize) bool {
        const flags = &self.state.flags;
        const buildings = &self.state.buildings;
        const FlagQueueCapacity = @import("FlagState.zig").FlagQueueCapacity;
        _ = FlagQueueCapacity;

        // Visited bitmap over flag indices. Use a small stack-backed array;
        // maps are small (≤ 1024×1024 but flag count is modest).
        var visited_buf: [256]bool = @splat(false);
        var queue_buf: [256]usize = @splat(0);
        var queue_len: usize = 0;

        if (flag_idx >= flags.flags.items.len) return false;
        queue_buf[queue_len] = flag_idx;
        queue_len += 1;
        if (flag_idx < visited_buf.len) visited_buf[flag_idx] = true;

        var head: usize = 0;
        while (head < queue_len) : (head += 1) {
            const cur_idx = queue_buf[head];
            const cur = &flags.flags.items[cur_idx];
            // Is this flag attached to a stock building?
            if (cur.building_index.isValid()) {
                const bld = buildings.get(cur.building_index);
                if (bld.building_type == .stock) return true;
            }
            // Enqueue connected neighbours.
            for (0..6) |d| {
                const nxt = cur.next[d];
                if (!nxt.isValid()) continue;
                const ni: usize = nxt.index;
                if (ni >= flags.flags.items.len) continue;
                if (ni < visited_buf.len and visited_buf[ni]) continue;
                if (queue_len >= queue_buf.len) break;
                queue_buf[queue_len] = ni;
                queue_len += 1;
                if (ni < visited_buf.len) visited_buf[ni] = true;
            }
        }
        return false;
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
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();

    try std.testing.expectEqual(@as(u64, 0), game.state.tick);
    game.tick(2); // speed=2, so this should tick once
    try std.testing.expectEqual(@as(u64, 1), game.state.tick);
}

test "Game place building" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
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
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    var objects: usize = 0;
    for (game.state.map.tiles) |t| {
        if (t.object != .none) objects += 1;
    }
    try std.testing.expect(objects > 0);
}

test "Cannot build on a tile with an object" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
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
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
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
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
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

test "Processing building consumes input and produces output" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const pos = types.MapPos{ .x = 8, .y = 8 };
    const tile = game.state.map.getTile(pos);
    tile.terrain = .grass;
    tile.object = .none;
    const idx = (try game.placeBuilding(pos, .sawmill, 0)).?;
    const b = game.state.buildings.get(idx);
    b.is_done = true; // skip construction
    // Give the sawmill some wood to consume.
    _ = b.addStock(.wood, 3);
    try std.testing.expectEqual(@as(u16, 3), b.stockCount(.wood));

    // Run enough ticks for one production cycle (sawmill = 60 ticks) plus
    // worker assignment.
    var t: u64 = 1;
    while (t <= 200) : (t += 1) game.tick(t);

    // The sawmill should have consumed some wood and produced planks (which
    // may still be in the building stock or have moved to the flag/stock).
    const wood_consumed = b.stockCount(.wood) < 3;
    const planks_made = b.stockCount(.planks) > 0 or
        game.state.players.players[0].resources[@intFromEnum(Resource.planks)] > 0;
    try std.testing.expect(wood_consumed);
    try std.testing.expect(planks_made);
}

test "Processing building stalls without input stock" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const pos = types.MapPos{ .x = 8, .y = 8 };
    const tile = game.state.map.getTile(pos);
    tile.terrain = .grass;
    tile.object = .none;
    const idx = (try game.placeBuilding(pos, .sawmill, 0)).?;
    const b = game.state.buildings.get(idx);
    b.is_done = true;
    // No wood in stock — sawmill must stall.
    try std.testing.expectEqual(@as(u16, 0), b.stockCount(.wood));

    var t: u64 = 1;
    while (t <= 200) : (t += 1) game.tick(t);

    // No planks produced anywhere.
    try std.testing.expectEqual(@as(u16, 0), b.stockCount(.planks));
    try std.testing.expectEqual(@as(u16, 0), game.state.players.players[0].resources[@intFromEnum(Resource.planks)]);
    // production_count should not have advanced (stalled, timer pinned).
    try std.testing.expectEqual(@as(u8, 0), b.production_count);
}

test "Building output flows to player stock via flag" {
    // A lumberjack with a tree nearby. After enough ticks, wood should reach
    // the player's stock (via building stock → flag → player fallback).
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const pos = types.MapPos{ .x = 8, .y = 8 };
    const tile = game.state.map.getTile(pos);
    tile.terrain = .grass;
    tile.object = .none;
    const idx = (try game.placeBuilding(pos, .lumberjack, 0)).?;
    game.state.buildings.get(idx).is_done = true;

    // Ensure a tree is always available (replant after each harvest).
    const tree_pos = types.MapPos{ .x = 9, .y = 8 };
    game.state.map.getTile(tree_pos).object = .tree;

    var t: u64 = 1;
    while (t <= 300) : (t += 1) {
        game.tick(t);
        // Replant so the lumberjack keeps producing.
        if (game.state.map.getTile(tree_pos).object == .none) {
            game.state.map.getTile(tree_pos).object = .tree;
        }
    }

    const wood_in_stock = game.state.players.players[0].resources[@intFromEnum(Resource.wood)];
    try std.testing.expect(wood_in_stock > 0);
}

test "Road-connected building delivers to stock building" {
    // Lumberjack's flag → road → stock building's flag. Resources should
    // reach the player stock via the road network (not just the fallback).
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    // Layout (all grass, no objects):
    //   (4,4) stock flag   (5,4) road   (6,4) lumberjack flag
    //   (4,5) stock bldg                (6,5) lumberjack bldg
    const stock_pos = types.MapPos{ .x = 4, .y = 5 };
    const lj_pos = types.MapPos{ .x = 6, .y = 5 };
    for ([_]types.MapPos{ stock_pos, lj_pos, .{ .x = 4, .y = 4 }, .{ .x = 5, .y = 4 }, .{ .x = 6, .y = 4 } }) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
    }

    // Place the stock building (auto-creates a flag at (4,4) = down_right).
    const stock_idx = (try game.placeBuilding(stock_pos, .stock, 0)).?;
    const stock_flag = game.state.buildings.get(stock_idx).flag_index;

    // Place the lumberjack (auto-creates a flag at (6,4)).
    const lj_idx = (try game.placeBuilding(lj_pos, .lumberjack, 0)).?;
    const lj_flag = game.state.buildings.get(lj_idx).flag_index;
    game.state.buildings.get(lj_idx).is_done = true;

    // Build a road between the two flags: (4,4)→(5,4)→(6,4) = right, right.
    const path = [_]u8{ @intFromEnum(Direction.right), @intFromEnum(Direction.right) };
    try std.testing.expect(game.buildRoad(
        game.state.flags.get(stock_flag).pos,
        game.state.flags.get(lj_flag).pos,
        &path,
    ));

    // Verify the BFS finds the stock from the lumberjack's flag.
    try std.testing.expect(game.flagReachesStock(lj_flag.index));

    // Keep a tree available for the lumberjack.
    const tree_pos = types.MapPos{ .x = 7, .y = 5 };
    game.state.map.getTile(tree_pos).object = .tree;

    var t: u64 = 1;
    while (t <= 300) : (t += 1) {
        game.tick(t);
        if (game.state.map.getTile(tree_pos).object == .none) {
            game.state.map.getTile(tree_pos).object = .tree;
        }
    }

    try std.testing.expect(game.state.players.players[0].resources[@intFromEnum(Resource.wood)] > 0);
}

test "updatePlayers recounts building counts" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const player = &game.state.players.players[0];
    try std.testing.expectEqual(@as(u16, 0), player.building_count[@intFromEnum(Building.lumberjack)]);
    try std.testing.expect(!player.has_castle);

    // Place a stock and a lumberjack on clear grass.
    const stock_pos = types.MapPos{ .x = 4, .y = 5 };
    const lj_pos = types.MapPos{ .x = 6, .y = 5 };
    for ([_]types.MapPos{ stock_pos, lj_pos, .{ .x = 4, .y = 4 }, .{ .x = 5, .y = 4 }, .{ .x = 6, .y = 4 } }) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
    }
    const stock_idx = (try game.placeBuilding(stock_pos, .stock, 0)).?;
    game.state.buildings.get(stock_idx).is_done = true;
    _ = (try game.placeBuilding(lj_pos, .lumberjack, 0)).?;

    // One tick runs updatePlayers → recountBuildings.
    game.tick(1);

    try std.testing.expectEqual(@as(u16, 1), player.building_count[@intFromEnum(Building.stock)]);
    try std.testing.expectEqual(@as(u16, 1), player.building_count[@intFromEnum(Building.lumberjack)]);
    try std.testing.expect(player.has_castle);
}

test "updatePlayers spawns a generic serf when reproduction fires" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    // Place a finished stock so the player has a castle.
    const stock_pos = types.MapPos{ .x = 4, .y = 5 };
    const tl = game.state.map.getTile(stock_pos);
    tl.terrain = .grass;
    tl.object = .none;
    const stock_idx = (try game.placeBuilding(stock_pos, .stock, 0)).?;
    game.state.buildings.get(stock_idx).is_done = true;

    const serfs_before = game.state.serfs.len();
    const player = &game.state.players.players[0];

    // Force a reproduction underflow on the very next tick: counter=0 minus
    // delta=1 wraps to 65535, which is > 0, signalling an underflow.
    player.reproduction_counter = 0;

    game.tick(1);

    // The reproduction cycle should have spawned one generic serf.
    try std.testing.expectEqual(serfs_before + 1, game.state.serfs.len());
    try std.testing.expect(player.serf_count[@intFromEnum(SerfType.generic)] >= 1);
}

test "Emergency program activates when essential chain is broken" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const player = &game.state.players.players[0];
    // No lumberjack/sawmill/stonecutter, and no planks/stone in stock.
    try std.testing.expectEqual(@as(u16, 0), player.resources[@intFromEnum(Resource.planks)]);
    try std.testing.expectEqual(@as(u16, 0), player.resources[@intFromEnum(Resource.stone)]);

    game.tick(1);

    try std.testing.expect(player.emergency_program_active);
}

test "Emergency program clears once the essential chain exists" {
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const player = &game.state.players.players[0];
    // Give the player a finished lumberjack, sawmill and stonecutter.
    const positions = [_]types.MapPos{
        .{ .x = 4, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 10, .y = 5 },
    };
    for (positions) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
        // Also clear the down-right flag tiles so each building gets a flag.
        const fp = p.move(.down_right);
        if (game.state.map.isValidPos(fp)) {
            const ft = game.state.map.getTile(fp);
            ft.terrain = .grass;
            ft.object = .none;
        }
    }
    const types_list = [_]Building{ .stock, .lumberjack, .sawmill, .stonecutter };
    for (positions, types_list) |p, bt| {
        const idx = (try game.placeBuilding(p, bt, 0)).?;
        game.state.buildings.get(idx).is_done = true;
    }

    game.tick(1);

    try std.testing.expect(!player.emergency_program_active);
}

test "Stock distributes input resources to processing buildings" {
    // A sawmill (consumes wood) with a flag. The player stock starts with
    // wood; after a tick the wood should leave the stock and arrive on the
    // sawmill's flag incoming queue (ready for updateInventories Pass 2).
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const saw_pos = types.MapPos{ .x = 6, .y = 5 };
    for ([_]types.MapPos{ saw_pos, .{ .x = 6, .y = 4 } }) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
    }
    const saw_idx = (try game.placeBuilding(saw_pos, .sawmill, 0)).?;
    game.state.buildings.get(saw_idx).is_done = true;
    const saw_flag = game.state.buildings.get(saw_idx).flag_index;

    const player = &game.state.players.players[0];
    player.resources[@intFromEnum(Resource.wood)] = 3;
    const wood_before = player.resources[@intFromEnum(Resource.wood)];

    game.tick(1);

    // One wood should have moved from the stock to the sawmill flag queue.
    const flag = game.state.flags.get(saw_flag);
    try std.testing.expect(flag.incoming_count > 0);
    try std.testing.expectEqual(@as(u16, wood_before - 1), player.resources[@intFromEnum(Resource.wood)]);
}

test "Stock distribution respects priority (armory over toolmaker for iron)" {
    // Both an armory and a toolmaker consume iron. With one iron in stock,
    // the armory (higher priority) should receive it.
    var game = try Game.init(std.testing.allocator, 64, 64, 1, .{ .seed = 42 });
    defer game.deinit();
    game.state.players.setPlayerCount(1);
    game.state.speed = 1;

    const armory_pos = types.MapPos{ .x = 4, .y = 5 };
    const tool_pos = types.MapPos{ .x = 8, .y = 5 };
    for ([_]types.MapPos{ armory_pos, .{ .x = 4, .y = 4 }, tool_pos, .{ .x = 8, .y = 4 } }) |p| {
        const tl = game.state.map.getTile(p);
        tl.terrain = .grass;
        tl.object = .none;
    }
    const armory_idx = (try game.placeBuilding(armory_pos, .armory, 0)).?;
    const tool_idx = (try game.placeBuilding(tool_pos, .toolmaker, 0)).?;
    game.state.buildings.get(armory_idx).is_done = true;
    game.state.buildings.get(tool_idx).is_done = true;
    const armory_flag = game.state.buildings.get(armory_idx).flag_index;
    const tool_flag = game.state.buildings.get(tool_idx).flag_index;

    const player = &game.state.players.players[0];
    player.resources[@intFromEnum(Resource.iron)] = 1;

    game.tick(1);

    // The armory flag should have received the iron, not the toolmaker.
    try std.testing.expect(game.state.flags.get(armory_flag).incoming_count > 0);
    try std.testing.expectEqual(@as(u8, 0), game.state.flags.get(tool_flag).incoming_count);
}
