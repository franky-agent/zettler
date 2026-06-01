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

    pub fn isBuildable(self: Terrain) bool {
        return self == .grass or self == .tundra or self == .desert;
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
        inline for (std.meta.fields(Direction), 0..) |field, i| {
            const dir: Direction = @enumFromInt(field.value);
            result[i] = self.getNeighbor(pos, dir);
        }
        return result;
    }

    /// Find the direction from one tile to an adjacent tile.
    pub fn directionTo(self: Map, from: MapPos, to: MapPos) ?Direction {
        inline for (std.meta.fields(Direction)) |field| {
            const dir: Direction = @enumFromInt(field.value);
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

    /// Generate a simple terrain using diamond-square (value noise).
    /// Terrain types use only values present in the original C++ terrain enum
    /// (Water, Grass, Tundra, Snow, Desert) — these have actual sprites in the
    /// AssetMapGround bank (PAK 260-292). Mountain/swamp/lava are not used here
    /// because no PAK sprites exist for them.
    pub fn generateTerrain(self: *Map, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        const w = self.width;
        const h = self.height;

        // Fill with random heights and map to terrain types with sprites.
        // Height progression: water (0-3) → grass (4-9) → tundra (10-12) → snow (13-15)
        for (0..h) |y| {
            for (0..w) |x| {
                const pos = MapPos{ .x = @intCast(x), .y = @intCast(y) };
                const height: u4 = @intCast(r.uintLessThan(u32, 16));
                self.getTile(pos).height = height;
                const terrain: Terrain = if (height <= TerrainGen.water_threshold)
                    .water
                else if (height >= 13)
                    .snow
                else if (height >= 10)
                    .tundra
                else
                    .grass;
                self.getTile(pos).terrain = terrain;
            }
        }

        // Smooth out isolated water tiles surrounded by walkable land.
        for (0..h) |y| {
            for (0..w) |x| {
                const pos = MapPos{ .x = @intCast(x), .y = @intCast(y) };
                if (self.getTile(pos).terrain == .water) {
                    const neighbors = self.getAllNeighbors(pos);
                    var walkable_count: u8 = 0;
                    for (neighbors) |n| {
                        if (n.eql(MapPos.invalid)) continue;
                        if (self.getTile(n).terrain.isWalkable()) walkable_count += 1;
                    }
                    if (walkable_count >= 4) {
                        self.getTile(pos).terrain = .grass;
                    }
                }
            }
        }
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
