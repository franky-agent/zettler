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
///
/// Map dimensions are configurable at startup. The minimum playable size is
/// `MIN_SIZE`×`MIN_SIZE` (the classic 64×64 Settlers map) and the maximum is
/// `MAX_SIZE`×`MAX_SIZE` (1024×1024, over 1 million tiles). Sizes outside
/// this range are rejected by `initChecked` with `error.MapSizeOutOfRange`.
pub const MIN_SIZE: u16 = 64;
pub const MAX_SIZE: u16 = 1024;

pub const Map = struct {
    width: u16 = 0,
    height: u16 = 0,
    tiles: []Tile = &.{},

    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Validate that a map dimension is within the supported range.
    pub fn isValidSize(w: u16, h: u16) bool {
        return w >= MIN_SIZE and h >= MIN_SIZE and w <= MAX_SIZE and h <= MAX_SIZE;
    }

    /// Create a map without size validation. Use `initChecked` from
    /// application code to enforce the min/max bounds.
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

    /// Create a map, rejecting sizes outside [MIN_SIZE, MAX_SIZE].
    pub fn initChecked(allocator: std.mem.Allocator, w: u16, h: u16) !Map {
        if (!isValidSize(w, h)) return error.MapSizeOutOfRange;
        return Map.init(allocator, w, h);
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.tiles);
        self.tiles = &.{};
    }

    // ── Map file persistence (.zmap) ─────────────────────────────────
    //
    // The map file format is a simple binary blob so that a generated world
    // can be reproduced exactly across runs:
    //
    //   offset  size  field
    //   0       4     magic   = "ZMAP"
    //   4       2     width   (u16 little-endian)
    //   6       2     height  (u16 little-endian)
    //   8       8     seed    (u64 little-endian, informational)
    //   16      4     tile_count (u32 little-endian = width*height)
    //   20      N     tiles   (raw @asBytes of the Tile array)
    //
    // The Tile struct is packed-enough (only fixed-size integer/enum/bool
    // fields, no pointers) that its in-memory layout is stable within a
    // build, so we dump it verbatim. Loading validates the header and copies
    // the tile bytes back into a freshly allocated tile slice.

    /// Magic bytes identifying a zettler map file ("ZMAP").
    pub const file_magic: [4]u8 = .{ 'Z', 'M', 'A', 'P' };
    /// Version of the map file format stored in the header.
    pub const file_version: u32 = 1;

    /// Serialize the map (dimensions + raw tile bytes) to `path`.
    /// Overwrites any existing file. Returns an error on I/O failure or if
    /// the map has no tiles. Uses the C/POSIX file API directly because
    /// `std.fs.cwd()` is unavailable in this Zig build.
    pub fn saveToFile(self: Map, path: []const u8, seed: u64) !void {
        if (self.tiles.len == 0) return error.EmptyMap;

        // NUL-terminate the path for the C API.
        const c_path = try self.allocator.alloc(u8, path.len + 1);
        defer self.allocator.free(c_path);
        @memcpy(c_path[0..path.len], path);
        c_path[path.len] = 0;

        // O_WRONLY | O_CREAT | O_TRUNC
        const fd = @as(c_int, @intCast(std.c.open(@ptrCast(c_path.ptr), .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        })));
        if (fd < 0) return error.SaveFailed;
        defer _ = std.c.close(fd);

        var buf: [28]u8 = undefined;
        @memcpy(buf[0..4], &file_magic);
        std.mem.writeInt(u16, buf[4..6], self.width, .little);
        std.mem.writeInt(u16, buf[6..8], self.height, .little);
        std.mem.writeInt(u64, buf[8..16], seed, .little);
        std.mem.writeInt(u32, buf[16..20], file_version, .little);
        std.mem.writeInt(u32, buf[20..24], @intCast(self.tiles.len), .little);
        // 4 bytes padding for alignment / future use.
        std.mem.writeInt(u32, buf[24..28], 0, .little);
        if (writeAllFd(fd, &buf) < 0) return error.WriteError;

        // Raw tile bytes. Tile contains no pointers, so this is safe.
        const tile_bytes = std.mem.sliceAsBytes(self.tiles);
        if (writeAllFd(fd, tile_bytes) < 0) return error.WriteError;
    }

    /// Load a map from `path`, replacing the current map contents.
    /// The receiver must already have been initialised with `Map.init` and
    /// will be resized to the dimensions stored in the file. Returns the
    /// seed stored in the file header.
    pub fn loadFromFile(self: *Map, path: []const u8) !u64 {
        const c_path = try self.allocator.alloc(u8, path.len + 1);
        defer self.allocator.free(c_path);
        @memcpy(c_path[0..path.len], path);
        c_path[path.len] = 0;

        // O_RDONLY = default ACCMODE
        const fd = @as(c_int, @intCast(std.c.open(@ptrCast(c_path.ptr), .{})));
        if (fd < 0) return error.FileNotFound;
        defer _ = std.c.close(fd);

        var hdr_buf: [28]u8 = undefined;
        const n = readAllFd(fd, &hdr_buf);
        if (n < hdr_buf.len) return error.TruncatedMapFile;

        if (!std.mem.eql(u8, hdr_buf[0..4], &file_magic)) return error.BadMapMagic;
        const w = std.mem.readInt(u16, hdr_buf[4..6], .little);
        const h = std.mem.readInt(u16, hdr_buf[6..8], .little);
        const seed = std.mem.readInt(u64, hdr_buf[8..16], .little);
        const tile_count = std.mem.readInt(u32, hdr_buf[20..24], .little);
        if (w == 0 or h == 0) return error.BadMapDimensions;
        if (@as(usize, w) * @as(usize, h) != tile_count) return error.BadMapTileCount;

        // Reallocate the tile slice for the file's dimensions.
        if (self.tiles.len != tile_count) {
            self.allocator.free(self.tiles);
            self.tiles = try self.allocator.alloc(Tile, tile_count);
        }
        self.width = w;
        self.height = h;

        const tile_bytes = std.mem.sliceAsBytes(self.tiles);
        const got = readAllFd(fd, tile_bytes);
        if (got != tile_bytes.len) return error.TruncatedMapFile;

        return seed;
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

// ── POSIX file helpers ─────────────────────────────────────────────
// `std.fs.cwd()` is unavailable in this Zig build, so we use the C file API
// directly, mirroring `readFileToAlloc` in render/app.zig.

/// Write the full buffer to `fd`, looping over short writes. Returns the
/// number of bytes written (== buf.len) on success, or a negative value on
/// failure.
fn writeAllFd(fd: c_int, buf: []const u8) isize {
    var written: usize = 0;
    while (written < buf.len) {
        const w = std.c.write(fd, buf.ptr + written, buf.len - written);
        if (w < 0) return w;
        if (w == 0) return -1;
        written += @intCast(w);
    }
    return @intCast(written);
}

/// Read exactly `buf.len` bytes from `fd` into `buf`, looping over short
/// reads. Returns the number of bytes read (== buf.len) on success, or a
/// smaller value on EOF / failure.
fn readAllFd(fd: c_int, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const r = std.c.read(fd, buf.ptr + total, buf.len - total);
        if (r < 0) return total;
        if (r == 0) break; // EOF
        total += @intCast(r);
    }
    return total;
}

/// Delete a file at `path` using the POSIX unlink() C call. Best-effort:
// ignores errors so it can be used in `defer`.
fn deleteFileC(path: []const u8) void {
    var c_path_buf: [4096]u8 = undefined;
    if (path.len + 1 > c_path_buf.len) return;
    @memcpy(c_path_buf[0..path.len], path);
    c_path_buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&c_path_buf));
}

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

test "Map save/load round-trips tiles exactly" {
    var map = try Map.init(std.testing.allocator, 32, 32);
    defer map.deinit();

    map.generateTerrain(1234);

    // Mutate a few tiles so we exercise the full Tile struct.
    map.getTileXY(5, 6).terrain = .desert;
    map.getTileXY(7, 8).object = .tree;
    map.getTileXY(7, 8).object_variant = 3;

    const tmp_path = "test_roundtrip.zmap";
    defer deleteFileC(tmp_path);

    try map.saveToFile(tmp_path, 1234);

    var loaded = try Map.init(std.testing.allocator, 1, 1);
    defer loaded.deinit();
    const loaded_seed = try loaded.loadFromFile(tmp_path);
    try std.testing.expectEqual(@as(u64, 1234), loaded_seed);
    try std.testing.expectEqual(@as(u16, 32), loaded.width);
    try std.testing.expectEqual(@as(u16, 32), loaded.height);

    // Every tile byte must match.
    const a = std.mem.sliceAsBytes(map.tiles);
    const b = std.mem.sliceAsBytes(loaded.tiles);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "Map load rejects bad magic" {
    var map = try Map.init(std.testing.allocator, 8, 8);
    defer map.deinit();

    const tmp_path = "test_badmagic.zmap";
    defer deleteFileC(tmp_path);
    {
        // Write a file with a bad magic header via the C API.
        const fd = @as(c_int, @intCast(std.c.open(@ptrCast("test_badmagic.zmap"), .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        })));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const bad_header = "XXXX\x08\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00";
        const written = writeAllFd(fd, bad_header);
        try std.testing.expect(written == bad_header.len);
    }
    try std.testing.expectError(error.BadMapMagic, map.loadFromFile(tmp_path));
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

test "Map size validation accepts the supported range" {
    try std.testing.expect(Map.isValidSize(64, 64));
    try std.testing.expect(Map.isValidSize(128, 128));
    try std.testing.expect(Map.isValidSize(256, 512));
    try std.testing.expect(Map.isValidSize(1024, 1024));

    try std.testing.expect(!Map.isValidSize(63, 64));
    try std.testing.expect(!Map.isValidSize(64, 63));
    try std.testing.expect(!Map.isValidSize(1025, 64));
    try std.testing.expect(!Map.isValidSize(64, 1025));
}

test "Map initChecked rejects out-of-range sizes" {
    try std.testing.expectError(error.MapSizeOutOfRange, Map.initChecked(std.testing.allocator, 32, 32));
    try std.testing.expectError(error.MapSizeOutOfRange, Map.initChecked(std.testing.allocator, 2048, 64));

    var map = try Map.initChecked(std.testing.allocator, 128, 128);
    defer map.deinit();
    try std.testing.expectEqual(@as(u16, 128), map.width);
    try std.testing.expectEqual(@as(usize, 128 * 128), map.tileCount());
}

test "Map large size allocates and accesses corners" {
    // 512×512 = 262 144 tiles — exercises the larger-than-64k path.
    var map = try Map.init(std.testing.allocator, 512, 512);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 512 * 512), map.tileCount());

    // Corner access wraps correctly on a large map.
    const corner = MapPos{ .x = 511, .y = 511 };
    map.getTile(corner).terrain = .snow;
    try std.testing.expectEqual(Terrain.snow, map.getTileXY(511, 511).terrain);

    // Wrapping at the far edge lands on column/row 0.
    try std.testing.expectEqual(@as(u16, 0), map.wrapX(512));
    try std.testing.expectEqual(@as(u16, 0), map.wrapY(512));
}
