//! Map — the hex grid tile map.
//!
//! Port of the C# Map class. Enhanced with terrain generation,
//! height operations, resource distribution, and pathfinding helpers.

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");

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
    /// (generateTerrain emits `tundra` as the rocky mountain rather than the
    /// `mountain` enum values, so tundra is the practical mining terrain.)
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

/// The game map — a dense hex grid.
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

    /// Generate terrain with a SMOOTH height field.
    ///
    /// A smooth height field is essential for correct rendering: the map
    /// renderer picks a terrain "slope sprite" (one of 8 variants per terrain
    /// band) based on the height difference to neighboring tiles. If heights
    /// were fully random per tile, every tile would pick a different slope
    /// sprite and the terrain would look like a chaotic checkerboard rather
    /// than a continuous landscape. By smoothing, neighbors share heights, most
    /// tiles become "flat" (variant 4) using the same base sprite, and the
    /// terrain blends seamlessly — matching the original Settlers look.
    ///
    /// Terrain types use only values present in the original C++ terrain enum
    /// (Water, Grass, Tundra, Snow, Desert) — these have actual sprites in the
    /// AssetMapGround bank (PAK 260-292). Mountain/swamp/lava are not used here.
    pub fn generateTerrain(self: *Map, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        const w: usize = self.width;
        const h: usize = self.height;
        const n = w * h;

        // Working height buffer in f32 for smoothing.
        const field = self.allocator.alloc(f32, n) catch {
            // Fallback: flat grass if allocation fails.
            for (self.tiles) |*t| {
                t.* = .{ .terrain = .grass, .height = 8 };
            }
            return;
        };
        defer self.allocator.free(field);

        // 1. Seed with random noise across the full height range.
        for (field) |*v| v.* = @floatFromInt(r.uintLessThan(u32, 16));

        // 2. Box-blur several passes. Each pass averages a tile with its 4
        //    orthogonal neighbors, rapidly damping high-frequency noise into
        //    gentle rolling hills. More passes = smoother / larger features.
        const tmp = self.allocator.alloc(f32, n) catch field; // reuse on failure
        defer if (tmp.ptr != field.ptr) self.allocator.free(tmp);
        if (tmp.ptr != field.ptr) {
            var pass: usize = 0;
            while (pass < 6) : (pass += 1) {
                for (0..h) |y| {
                    for (0..w) |x| {
                        var sum: f32 = field[y * w + x];
                        var cnt: f32 = 1;
                        if (x > 0)     { sum += field[y * w + (x - 1)]; cnt += 1; }
                        if (x + 1 < w) { sum += field[y * w + (x + 1)]; cnt += 1; }
                        if (y > 0)     { sum += field[(y - 1) * w + x]; cnt += 1; }
                        if (y + 1 < h) { sum += field[(y + 1) * w + x]; cnt += 1; }
                        tmp[y * w + x] = sum / cnt;
                    }
                }
                @memcpy(field, tmp);
            }
        }

        // 3. Renormalize the smoothed field back to the full 0..15 range
        //    (blurring compresses the range toward the mean).
        var lo: f32 = field[0];
        var hi: f32 = field[0];
        for (field) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        const span = @max(hi - lo, 0.0001);

        // 4. Map smoothed heights → tile height + terrain band.
        //    Bands: water (0-3) → grass (4-9) → tundra (10-12) → snow (13-15)
        for (0..h) |y| {
            for (0..w) |x| {
                const idx = y * w + x;
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

        // 5. Smooth out isolated water tiles surrounded by walkable land.
        for (0..h) |y| {
            for (0..w) |x| {
                const pos = MapPos{ .x = @intCast(x), .y = @intCast(y) };
                if (self.getTile(pos).terrain == .water) {
                    const neighbors = self.getAllNeighbors(pos);
                    var walkable_count: u8 = 0;
                    for (neighbors) |nb| {
                        if (nb.eql(MapPos.invalid)) continue;
                        if (self.getTile(nb).terrain.isWalkable()) walkable_count += 1;
                    }
                    if (walkable_count >= 4) {
                        self.getTile(pos).terrain = .grass;
                    }
                }
            }
        }

        // 6. Scatter harvestable objects: trees (deciduous + pine) on grass,
        //    rocks on the rocky tundra band. These are what gatherers consume.
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
    pub fn findNearestObject(self: *Map, pos: MapPos, radius: i32, want_tree: bool) ?MapPos {
        var best: ?MapPos = null;
        var best_d: i32 = std.math.maxInt(i32);
        const px: i32 = @intCast(pos.x);
        const py: i32 = @intCast(pos.y);
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                const tx = px + dx;
                const ty = py + dy;
                if (tx < 0 or ty < 0 or tx >= self.width or ty >= self.height) continue;
                const t = self.getTileXY(@intCast(tx), @intCast(ty));
                const match = if (want_tree) t.object.isTree() else (t.object == .stone);
                if (!match) continue;
                const d = dx * dx + dy * dy;
                if (d < best_d) {
                    best_d = d;
                    best = MapPos{ .x = @intCast(tx), .y = @intCast(ty) };
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
    // generateTerrain only emits terrain types that have PAK sprites (water, grass,
    // tundra, snow) — mountain/swamp/lava are never generated.
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
            // mountain/swamp/lava must never be generated
            try std.testing.expect(tile.terrain != .mountain);
            try std.testing.expect(tile.terrain != .swamp);
            try std.testing.expect(tile.terrain != .lava);
        }
    }

    try std.testing.expect(water_count > 0);
    try std.testing.expect(snow_count > 0);
    try std.testing.expect(other_count > 0);
}
