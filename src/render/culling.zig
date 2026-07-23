//! Viewport culling helpers.
//!
//! Converts the camera's visible world-space rectangle into a tile
//! column/row range so that the CPU-side render passes (map objects,
//! buildings, roads, waves) only iterate over tiles that can actually be
//! seen, instead of the entire map.
//!
//! The map uses the sheared isometric projection:
//!   screen_x = col * TileWidth - row * (TileWidth/2)
//!   screen_y = row * TileHeight
//!
//! To find which tiles intersect a world rectangle `(min_x..max_x, min_y..max_y)`
//! we invert the projection conservatively:
//!   row range: [floor(min_y / TileHeight) - MARGIN, ceil(max_y / TileHeight) + MARGIN]
//!   col range (per row, due to the shear): a tile at (col,row) spans world x
//!     [col*TileW - row*TileW/2, (col+1)*TileW - row*TileW/2], so
//!     col_lo = floor((min_x + row*TileW/2) / TileW) - MARGIN
//!     col_hi = ceil ((max_x + row*TileW/2) / TileW) + MARGIN
//!
//! A margin is added for sprite footprints (trees and buildings extend above
//! their anchor tile). Each tile is then wrapped with `@mod` into the map.

const std = @import("std");
const core = @import("core");

const Map = core.map.Map;
const MapPos = core.MapPos;

/// Tile dimensions — must match `map_renderer.TileWidth/TileHeight`.
pub const TileWidth: f32 = 32.0;
pub const TileHeight: f32 = 20.0;

/// Extra tiles of margin around the computed range for sprite footprints.
pub const MARGIN: i32 = 3;

/// Iterator over every visible tile, wrapping into the map's torus. Each tile
/// is visited at most once even if the visible range spans more than a full
/// map period (the row/col ranges are clamped to one period).
pub const TileIter = struct {
    map_w: i32,
    map_h: i32,
    row_lo: i32,
    row_hi: i32,
    col_lo: i32,
    col_hi: i32,
    row: i32,
    col: i32,
    /// Optional visited bitmap (sized ceil(map_w*map_h/8) bytes) to suppress
    /// duplicate tiles when the view spans more than one period.
    visited: []u8 = &.{},
    /// Number of tiles the bitmap can hold (map_w * map_h), NOT the byte
    /// length of the `visited` slice.
    visited_bits: usize = 0,

    pub fn next(self: *TileIter) ?MapPos {
        while (self.row <= self.row_hi) {
            while (self.col <= self.col_hi) {
                const c = self.col;
                const r = self.row;
                self.col += 1;
                if (self.map_w == 0 or self.map_h == 0) return null;
                const w: i32 = @mod(c, self.map_w);
                const h: i32 = @mod(r, self.map_h);
                const lin: usize = @intCast(h * self.map_w + w);
                if (self.visited_bits > 0 and lin < self.visited_bits) {
                    const byte_idx = lin >> 3;
                    const bit_mask: u8 = @as(u8, 1) << @intCast(lin & 7);
                    if (self.visited[byte_idx] & bit_mask != 0) continue;
                    self.visited[byte_idx] |= bit_mask;
                }
                return .{ .x = @intCast(w), .y = @intCast(h) };
            }
            self.col = self.col_lo;
            self.row += 1;
        }
        return null;
    }
};

/// Compute a tile iterator for the visible region. `visited_buf` is an
/// optional scratch buffer (sized `ceil(map_w * map_h / 8)` bytes) used to
/// avoid emitting duplicates when the view spans more than one full period;
/// pass `&.{}` to allow duplicates (cheaper for small ranges).
pub fn visibleTiles(
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    map: Map,
    visited_buf: []u8,
) TileIter {
    const hw = TileWidth * 0.5;
    const map_w: i32 = @intCast(map.width);
    const map_h: i32 = @intCast(map.height);

    // Row range from world y bounds.
    const row_lo = @as(i32, @intFromFloat(@floor(min_y / TileHeight))) - MARGIN;
    const row_hi = @as(i32, @intFromFloat(@ceil(max_y / TileHeight))) + MARGIN;

    // Column range: the shear shifts columns by row*(TileW/2). Use the most
    // extreme rows to get a conservative bounding box covering all rows.
    const off_lo = @as(f32, @floatFromInt(row_lo)) * hw;
    const off_hi = @as(f32, @floatFromInt(row_hi)) * hw;
    const off_min = @min(off_lo, off_hi);
    const off_max = @max(off_lo, off_hi);
    const col_lo = @as(i32, @intFromFloat(@floor((min_x + off_min) / TileWidth))) - MARGIN;
    const col_hi = @as(i32, @intFromFloat(@ceil((max_x + off_max) / TileWidth))) + MARGIN;

    // Clamp the iteration to at most one full period in each axis so we never
    // visit more tiles than the map contains.
    // Clamp the iteration to at most one full period in each axis so we never
    // visit more tiles than the map contains. When the span covers the whole
    // map, reset the range to [0, map_size-1] so all residues are visited
    // (important when row_lo/col_lo is negative).
    const r_span = row_hi - row_lo + 1;
    const c_span = col_hi - col_lo + 1;
    const clamped_row_lo: i32 = if (r_span >= map_h) 0 else row_lo;
    const clamped_row_hi: i32 = if (r_span >= map_h) map_h - 1 else row_hi;
    const clamped_col_lo: i32 = if (c_span >= map_w) 0 else col_lo;
    const clamped_col_hi: i32 = if (c_span >= map_w) map_w - 1 else col_hi;

    if (visited_buf.len > 0) @memset(visited_buf, 0);

    // visited_bits = number of tiles the bitmap can address (map_w * map_h).
    const visited_bits: usize = @as(usize, @intCast(map_w)) * @as(usize, @intCast(map_h));

    return .{
        .map_w = map_w,
        .map_h = map_h,
        .row_lo = clamped_row_lo,
        .row_hi = clamped_row_hi,
        .col_lo = clamped_col_lo,
        .col_hi = clamped_col_hi,
        .row = clamped_row_lo,
        .col = clamped_col_lo,
        .visited = visited_buf,
        .visited_bits = if (visited_buf.len > 0) visited_bits else 0,
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "visibleTiles covers a centered view on a 64x64 map" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();
    var it = visibleTiles(-256, -192, 256, 192, map, &.{});
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expect(count > 100);
    try std.testing.expect(count < 4096);
}

test "visibleTiles covers everything when zoomed out fully" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();
    var it = visibleTiles(-10000, -10000, 10000, 10000, map, &.{});
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expect(count <= 64 * 64);
    try std.testing.expect(count > 0);
}

test "visibleTiles no duplicates with visited buffer" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();
    var buf: [64 * 64 / 8 + 1]u8 = undefined;
    var it = visibleTiles(-10000, -10000, 10000, 10000, map, &buf);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 64 * 64), count);
}

test "visibleTiles no duplicates on a 512x512 map with visited buffer" {
    // Regression: visited_len was set to the byte length of the buffer
    // (131072) instead of the tile count (262144), so the bitmap only
    // deduped the first half of the map.
    var map = try Map.init(std.testing.allocator, 512, 512);
    defer map.deinit();
    const buf_bytes = (512 * 512 + 7) / 8;
    const buf = try std.testing.allocator.alloc(u8, buf_bytes);
    defer std.testing.allocator.free(buf);
    var it = visibleTiles(-100000, -100000, 100000, 100000, map, buf);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 512 * 512), count);
}

test "visibleTiles handles negative row_lo with full-map span" {
    // Regression: when the span covered the whole map and row_lo was
    // negative, clamped_row_hi = row_lo + map_h - 1 missed residues.
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();
    var buf: [64 * 64 / 8 + 1]u8 = undefined;
    var it = visibleTiles(-10000, -10000, 10000, 10000, map, &buf);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    // With the fix, all 64*64 tiles are visited exactly once.
    try std.testing.expectEqual(@as(usize, 64 * 64), count);
}
