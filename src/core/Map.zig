//! Map — the hex grid tile map.
//!
//! Port of the C# Map class. Enhanced with Perlin noise terrain generation,
//! torus-wrapping support (seamless world edges), and pathfinding helpers.
//!
//! The map is a finite grid that wraps toroidally: scrolling past the right
//! edge shows the left edge, past the bottom shows the top, etc. Gameplay
//! operations (buildings, flags, roads, pathfinding) also wrap — a road
//! exiting the right side connects to column 0 on the left.

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const noise_mod = @import("Noise.zig");

const Direction = enums.Direction;
const MapPos = types.MapPos;
const GameObjectIndex = types.GameObjectIndex;

/// Terrain types for a map tile.
pub const Terrain = enum(u4) {
    water = 0,
    grass = 1,
    tundra = 2,
    snow = 3,
    swamp = 4,
    lava = 5,
    desert = 6,
    mountain = 7,
    mountain2 = 8,
    mountain_mined = 9,
    mountain_flagged = 10,

    pub const count = 11;

    pub fn isWater(self: Terrain) bool {
        return self == .water;
    }

    pub fn isMountain(self: Terrain) bool {
        return @intFromEnum(self) >= 7;
    }

    pub fn isWalkable(self: Terrain) bool {
        return !self.isWater() and !self.isMountain();
    }

    /// Whether normal (non-mine) buildings can be placed here: grass (and flat
    /// desert sand). Matches freeserf's can_build_small (grass only); tundra and
    /// snow are the mountain band reserved for mines, water is never buildable.
    pub fn isBuildable(self: Terrain) bool {
        return self == .grass or self == .desert;
    }

    /// Whether a mine can be placed here. Mines dig into rock, so they go on the
    /// rocky mountain band — `tundra` (the grey high ground) and the explicit
    /// mountain terrains. Snow caps are excluded (too high), as are grass/water.
    pub fn isMineable(self: Terrain) bool {
        return self == .tundra or self.isMountain();
    }
};

/// A standing object occupying a map tile (resource the gatherers harvest, or
/// scenery). Mirrors the freeserf Map::Object families we care about for the
/// economy. `variant` (0..7) selects the sprite within the family for visual
/// variety; see app.zig drawMapObjects for the AssetMapObject offsets.
pub const MapObject = enum(u8) {
    none = 0,
    tree = 1, // deciduous — felled by lumberjacks for wood
    pine = 2, // coniferous — also felled for wood
    stone = 3, // rock — cut by stonecutters for stone

    pub fn isTree(self: MapObject) bool {
        return self == .tree or self == .pine;
    }
};

/// A single tile on the map.
pub const Tile = struct {
    terrain: Terrain = .grass,
    height: u4 = 0,
    has_road: bool = false,
    has_flag: bool = false,
    has_building: bool = false,
    owner: u8 = 0xFF,
    building_index: GameObjectIndex = GameObjectIndex.invalid,
    flag_index: GameObjectIndex = GameObjectIndex.invalid,
    serf_index: GameObjectIndex = GameObjectIndex.invalid,
    ground_resource: u8 = 0,
    ground_resource_type: u8 = 0,
    /// Standing object on the tile (tree/rock/none). Blocks building placement.
    object: MapObject = .none,
    /// Sprite variant within the object family (0..7).
    object_variant: u8 = 0,
};

/// Terrain generation constants.
pub const TerrainGen = struct {
    pub const water_threshold = 3;
    pub const mountain_threshold = 12;
    pub const height_max = 15;
};

/// The game map — a dense hex grid that wraps toroidally.
pub const Map = struct {
    width: u16 = 0,
    height: u16 = 0,
    tiles: []Tile = &.{},

    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(allocator: std.mem.Allocator, w: u16, h: u16) !Map {
        const tile_count = @as(usize, w) * @as(usize, h);
        const tiles = try allocator.alloc(Tile, tile_count);
        @memset(tiles, Tile{});
        return .{
            .width = w,
            .height = h,
            .tiles = tiles,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.tiles);
        self.tiles = &.{};
    }

    pub fn getTile(self: Map, pos: MapPos) *Tile {
        const idx = pos.toIndex(self.width);
        return &self.tiles[idx];
    }

    pub fn getTileXY(self: Map, x: u16, y: u16) *Tile {
        return &self.tiles[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn tileCount(self: Map) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    pub fn isValidPos(self: Map, pos: MapPos) bool {
        return pos.x < self.width and pos.y < self.height;
    }

    pub fn isValidXY(self: Map, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }

    pub fn posToIndex(self: Map, pos: MapPos) u32 {
        return pos.toIndex(self.width);
    }

    pub fn indexToPos(self: Map, index: u32) MapPos {
        return MapPos.fromIndex(index, self.width);
    }

    // ── Torus (wrapping) coordinate helpers ──────────────────────────

    /// Wrap an x coordinate into [0, width). Supports negative and overflow values.
    /// Uses integer @mod which always returns non-negative results.
    pub fn wrapX(self: Map, x: i32) u16 {
        const w: i32 = @intCast(self.width);
        const result: i32 = @mod(x, w);
        return @intCast(result);
    }

    /// Wrap a y coordinate into [0, height). Supports negative and overflow values.
    /// Uses integer @mod which always returns non-negative results.
    pub fn wrapY(self: Map, y: i32) u16 {
        const h: i32 = @intCast(self.height);
        const result: i32 = @mod(y, h);
        return @intCast(result);
    }

    /// Get a tile at wrapped (torus) coordinates. Any integer x,y maps to a
    /// valid tile by wrapping around the map edges.
    pub fn getTileWrapped(self: Map, x: i32, y: i32) *Tile {
        return self.getTileXY(self.wrapX(x), self.wrapY(y));
    }

    /// Get the height at wrapped coordinates (for renderer height sampling).
    pub fn heightAtWrapped(self: Map, x: i32, y: i32) f32 {
        return @floatFromInt(self.getTileWrapped(x, y).height);
    }

    /// Wrap a MapPos into the valid range [0,width) × [0,height).
    /// Useful for converting raw movement results that may overflow.
    pub fn wrapPos(self: Map, pos: MapPos) MapPos {
        return .{ .x = self.wrapX(@intCast(pos.x)), .y = self.wrapY(@intCast(pos.y)) };
    }

    /// Get a neighboring tile in the given direction, wrapping around the
    /// torus. Always returns a valid position (never MapPos.invalid).
    pub fn getNeighborWrapped(self: Map, pos: MapPos, dir: Direction) MapPos {
        const raw = pos.move(dir);
        return self.wrapPos(raw);
    }

    /// Get all 6 neighboring positions with torus wrapping (always valid).
    pub fn getAllNeighborsWrapped(self: Map, pos: MapPos) [6]MapPos {
        var result: [6]MapPos = undefined;
        inline for (std.meta.tags(Direction), 0..) |dir, i| {
            result[i] = self.getNeighborWrapped(pos, dir);
        }
        return result;
    }

    /// Find the direction from one tile to an adjacent tile, supporting wrap.
    /// Returns null if `to` is not a direct neighbour of `from`.
    pub fn directionToWrapped(self: Map, from: MapPos, to: MapPos) ?Direction {
        inline for (std.meta.tags(Direction)) |dir| {
            const neighbor = self.getNeighborWrapped(from, dir);
            if (neighbor.eql(to)) return dir;
        }
        return null;
    }

    // ── Original (non-wrapping) neighbour methods kept for compatibility ──

    /// Get a neighboring tile in the given direction.
    /// Returns MapPos.invalid if the neighbor would be out of bounds.
    pub fn getNeighbor(self: Map, pos: MapPos, dir: Direction) MapPos {
        const result = pos.move(dir);
        if (self.isValidPos(result)) return result;
        return MapPos.invalid;
    }

    /// Get all 6 neighboring positions (some may be invalid).
    pub fn getAllNeighbors(self: Map, pos: MapPos) [6]MapPos {
        var result: [6]MapPos = @splat(MapPos.invalid);
        inline for (std.meta.tags(Direction), 0..) |dir, i| {
            result[i] = self.getNeighbor(pos, dir);
        }
        return result;
    }

    /// Find the direction from one tile to an adjacent tile.
    pub fn directionTo(self: Map, from: MapPos, to: MapPos) ?Direction {
        inline for (std.meta.tags(Direction)) |dir| {
            const neighbor = from.move(dir);
            if (self.isValidPos(neighbor) and neighbor.eql(to)) return dir;
        }
        return null;
    }

    /// Get the height at a position (returns 0 for invalid).
    pub fn getHeight(self: Map, pos: MapPos) u4 {
        if (!self.isValidPos(pos)) return 0;
        return self.getTile(pos).height;
    }

    /// Set a tile's terrain.
    pub fn setTerrain(self: *Map, pos: MapPos, terrain: Terrain) void {
        if (!self.isValidPos(pos)) return;
        self.getTile(pos).terrain = terrain;
    }

    /// Set a tile's height.
    pub fn setHeight(self: *Map, pos: MapPos, height: u4) void {
        if (!self.isValidPos(pos)) return;
        self.getTile(pos).height = height;
    }

    /// Set a tile's owner.
    pub fn setOwner(self: *Map, pos: MapPos, player: u8) void {
        if (!self.isValidPos(pos)) return;
        self.getTile(pos).owner = player;
    }

    /// Check if a tile is owned by a specific player.
    pub fn isOwnedBy(self: Map, pos: MapPos, player: u8) bool {
        if (!self.isValidPos(pos)) return false;
        return self.getTile(pos).owner == player;
    }

    /// Generate terrain using periodic Perlin noise (seamless torus wrapping).
    ///
    /// This uses multi-octave Perlin noise that is periodic in both X and Y
    /// with period = map width/height, guaranteeing that the left edge
    /// blends seamlessly into the right edge and the top into the bottom.
    ///
    /// Terrain types use only values present in the original C++ terrain enum
    /// (Water, Grass, Tundra, Snow, Desert) — these have actual sprites in the
    /// AssetMapGround bank (PAK 260-292). Mountain/swamp/lava are not used here.
    pub fn generateTerrain(self: *Map, seed: u64) void {
        const w: u32 = @intCast(self.width);
        const h: u32 = @intCast(self.height);

        // Build a seeded permutation table for Perlin noise.
        const perm = noise_mod.Permutation.init(seed);

        // 1. Generate height field using periodic Perlin noise.
        //    The noise is evaluated at (x * scale / w, y * scale / h) so that
        //    one period of noise spans the entire map, making edges tile.
        var lo: f64 = std.math.floatMax(f64);
        var hi: f64 = -std.math.floatMax(f64);

        // First pass: compute raw noise and find min/max for normalization.
        const n = @as(usize, self.width) * @as(usize, self.height);
        const field = self.allocator.alloc(f64, n) catch {
            // Fallback: flat grass if allocation fails.
            for (self.tiles) |*t| {
                t.* = .{ .terrain = .grass, .height = 8 };
            }
            return;
        };
        defer self.allocator.free(field);

        // Feature scale: how many tiles per Perlin grid cell. Larger values
        // give larger landmasses; smaller values give finer detail. With
        // scale=4, each Perlin grid cell spans 4 tiles, so the noise varies
        // smoothly across the map rather than collapsing to 0 at every
        // integer tile coordinate (Perlin noise is exactly 0 at integer
        // grid points, so sampling at raw integer tile coords yields a flat
        // field — this was the all-water bug).
        const feature_scale: f64 = 4.0;
        const px: f64 = @as(f64, @floatFromInt(w)) / feature_scale;
        const py: f64 = @as(f64, @floatFromInt(h)) / feature_scale;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const fx: f64 = @floatFromInt(x);
                const fy: f64 = @floatFromInt(y);
                // Sample the noise in a continuous domain: divide tile coords
                // by feature_scale so adjacent tiles land on different parts
                // of the Perlin field. The period is the map size divided by
                // the same factor, so the noise still tiles seamlessly at the
                // map edges (left↔right, top↔bottom).
                const sx = fx / feature_scale;
                const sy = fy / feature_scale;
                const height_noise = noise_mod.fbm_perlin2d(
                    sx, sy,
                    perm, @intFromFloat(px), @intFromFloat(py), 4,
                );
                const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
                field[idx] = height_noise;
                lo = @min(lo, height_noise);
                hi = @max(hi, height_noise);
            }
        }

        // 2. Renormalize to [0, 15] and assign terrain bands.
        const span = @max(hi - lo, 0.0001);

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
                const norm = (field[idx] - lo) / span; // 0..1
                const height: u4 = @intFromFloat(@min(15.0, norm * 15.0));
                const tile = &self.tiles[idx];
                tile.height = height;
                tile.terrain = if (height <= TerrainGen.water_threshold)
                    .water
                else if (height >= 13)
                    .snow
                else if (height >= 10)
                    .tundra
                else
                    .grass;
            }
        }

        // 3. Smooth out isolated water tiles surrounded by walkable land,
        //    using WRAPPING neighbour queries so edge water also gets cleaned.
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const pos = MapPos{ .x = @intCast(x), .y = @intCast(y) };
                if (self.getTile(pos).terrain == .water) {
                    const neighbors = self.getAllNeighborsWrapped(pos);
                    var walkable_count: u8 = 0;
                    for (neighbors) |nb| {
                        if (self.getTile(nb).terrain.isWalkable()) walkable_count += 1;
                    }
                    if (walkable_count >= 4) {
                        self.getTile(pos).terrain = .grass;
                    }
                }
            }
        }

        // 4. Scatter harvestable objects: trees on grass, rocks on tundra.
        self.populateObjects(seed ^ 0x5eed);
    }

    /// Scatter trees and rocks across the map. Trees go on grass (so foresters
    /// and lumberjacks have something to work with); rocks go on the tundra
    /// "mountain" band near the mines. Density is intentionally moderate so the
    /// map stays buildable. Safe to call once after generateTerrain.
    pub fn populateObjects(self: *Map, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const tile = self.getTileXY(@intCast(x), @intCast(y));
                if (tile.object != .none) continue;
                switch (tile.terrain) {
                    .grass => {
                        // ~22% tree cover, mixed deciduous/pine.
                        if (r.uintLessThan(u8, 100) < 22) {
                            tile.object = if (r.boolean()) .tree else .pine;
                            tile.object_variant = r.uintLessThan(u8, 8);
                        }
                    },
                    .tundra => {
                        // ~18% rock cover on the rocky mountain band.
                        if (r.uintLessThan(u8, 100) < 18) {
                            tile.object = .stone;
                            tile.object_variant = r.uintLessThan(u8, 8);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Count the harvestable objects of a family within `radius` tiles of `pos`,
    /// and return the nearest such tile (for gatherers). `want_tree` true → trees
    /// (deciduous/pine); false → rocks. Returns null if none in range.
    /// Uses wrapping coordinates so it works across map edges.
    pub fn findNearestObject(self: *Map, pos: MapPos, radius: i32, want_tree: bool) ?MapPos {
        var best: ?MapPos = null;
        var best_d: i32 = std.math.maxInt(i32);
        const px: i32 = @intCast(pos.x);
        const py: i32 = @intCast(pos.y);
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                // Use wrapping so we can find objects across map edges
                const tx = self.wrapX(px + dx);
                const ty = self.wrapY(py + dy);
                const t = self.getTileXY(tx, ty);
                const match = if (want_tree) t.object.isTree() else (t.object == .stone);
                if (!match) continue;
                const d = dx * dx + dy * dy;
                if (d < best_d) {
                    best_d = d;
                    best = MapPos{ .x = tx, .y = ty };
                }
            }
        }
        return best;
    }
};

test "Map creation and access" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();

    try std.testing.expectEqual(@as(u16, 64), map.width);
    try std.testing.expectEqual(@as(u16, 64), map.height);
    try std.testing.expectEqual(@as(usize, 64 * 64), map.tileCount());

    const pos = MapPos{ .x = 10, .y = 20 };
    const tile = map.getTile(pos);
    try std.testing.expectEqual(Terrain.grass, tile.terrain);
}

test "Map neighbor direction" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();

    const from = MapPos{ .x = 10, .y = 10 };
    const to = from.move(Direction.right);

    const dir = map.directionTo(from, to);
    try std.testing.expectEqual(Direction.right, dir);
}

test "Map terrain generation" {
    var map = try Map.init(std.testing.allocator, 32, 32);
    defer map.deinit();

    map.generateTerrain(42);

    // After generation we should have water, grassy lowland, and snowy highland.
    var water_count: usize = 0;
    var snow_count: usize = 0;
    var other_count: usize = 0;

    for (0..map.height) |y| {
        for (0..map.width) |x| {
            const tile = map.getTileXY(@intCast(x), @intCast(y));
            switch (tile.terrain) {
                .water => water_count += 1,
                .snow  => snow_count += 1,
                else   => other_count += 1,
            }
            try std.testing.expect(tile.terrain != .mountain);
            try std.testing.expect(tile.terrain != .swamp);
            try std.testing.expect(tile.terrain != .lava);
        }
    }

    try std.testing.expect(water_count > 0);
    try std.testing.expect(snow_count > 0);
    try std.testing.expect(other_count > 0);
}

test "Map wrapping coordinates" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();

    // wrapX / wrapY should wrap negative and overflow values
    try std.testing.expectEqual(@as(u16, 0), map.wrapX(64));
    try std.testing.expectEqual(@as(u16, 0), map.wrapY(64));
    try std.testing.expectEqual(@as(u16, 63), map.wrapX(-1));
    try std.testing.expectEqual(@as(u16, 63), map.wrapY(-1));
    try std.testing.expectEqual(@as(u16, 5), map.wrapX(69));
    try std.testing.expectEqual(@as(u16, 5), map.wrapX(-59));

    // wrapPos should handle wrapping
    const pos = map.wrapPos(.{ .x = 65, .y = 65 });
    try std.testing.expectEqual(@as(u16, 1), pos.x);
    try std.testing.expectEqual(@as(u16, 1), pos.y);
}

test "Map wrapped neighbour wraps around edges" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();

    // Moving right from the rightmost column wraps to column 0
    const right_edge = MapPos{ .x = 63, .y = 10 };
    const right_neighbor = map.getNeighborWrapped(right_edge, Direction.right);
    try std.testing.expectEqual(@as(u16, 0), right_neighbor.x);
    try std.testing.expectEqual(@as(u16, 10), right_neighbor.y);

    // Moving down from the bottom row wraps to row 0
    const bottom_edge = MapPos{ .x = 10, .y = 63 };
    const bottom_neighbor = map.getNeighborWrapped(bottom_edge, Direction.down);
    try std.testing.expectEqual(@as(u16, 10), bottom_neighbor.x);
    try std.testing.expectEqual(@as(u16, 0), bottom_neighbor.y);

    // Moving down-right from the bottom-right corner wraps both
    const corner = MapPos{ .x = 63, .y = 63 };
    const corner_neighbor = map.getNeighborWrapped(corner, Direction.down_right);
    try std.testing.expectEqual(@as(u16, 0), corner_neighbor.x);
    try std.testing.expectEqual(@as(u16, 0), corner_neighbor.y);
}

test "Map terrain generation is seamless at edges" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();

    map.generateTerrain(42);

    // Check that height is continuous across the wrap boundary.
    // The Perlin noise is periodic with period = map dimensions, so
    // height at (0, y) should be close to height at (width-1, y), etc.
    // We check that the difference is at most 2 height levels.
    for (0..map.height) |y| {
        const h_left = map.getTileXY(0, @intCast(y)).height;
        const h_right = map.getTileXY(63, @intCast(y)).height;
        const diff: i32 = @as(i32, @intCast(h_left)) - @as(i32, @intCast(h_right));
        try std.testing.expect(@abs(diff) <= 3);

        const h_top = map.getTileXY(@intCast(y), 0).height;
        const h_bottom = map.getTileXY(@intCast(y), 63).height;
        const diff_v: i32 = @as(i32, @intCast(h_top)) - @as(i32, @intCast(h_bottom));
        try std.testing.expect(@abs(diff_v) <= 3);
    }
}