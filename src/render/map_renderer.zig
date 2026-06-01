//! Map renderer — renders the hex grid terrain with textured quads.
//!
//! Each terrain tile is drawn as a diamond (like the original Settlers).
//! Uses the original Settlers isometric coordinate projection:
//!   screen_x = col * TileWidth  - row * (TileWidth/2)
//!   screen_y = row * TileHeight
//!
//! In the original C++ code, terrain sprites (AssetMapGround) are fully
//! opaque solid rectangles (SpriteTypeSolid). The diamond shape comes from
//! a separate mask system (AssetMapMaskUp/AssetMapMaskDown) plus rendering
//! each tile as two triangles. Here we achieve the same diamond shape by
//! rendering each tile as a 4-vertex diamond (up+down triangles).

const std = @import("std");
const gl = @import("gl.zig");
const core = @import("core");
const Shader = @import("Shader.zig").Shader;
const Camera = @import("Camera.zig").Camera;
const TextureAtlas = @import("texture_atlas.zig").TextureAtlas;

const Map = core.map.Map;
const MapPos = core.MapPos;
const Terrain = core.map.Terrain;

/// Tile dimensions in world pixels (match actual 32×20 terrain sprites).
pub const TileWidth: f32 = 32.0;
pub const TileHeight: f32 = 20.0;

/// First PAK index of the 32×20 terrain sprites (C++ AssetMapGround base).
pub const TERRAIN_SPRITE_BASE: u16 = 260;

/// Height-mask lookup table for the up-pointing triangle (from C++ viewport.cc tri_mask[]).
/// Index = 4 + (m - left) + 9 * (4 + (m - right)), clamped to [0,8] each axis.
/// Returns sprite variant 0-7, or -1 for invalid combinations.
const TRI_MASK_UP = [81]i8{
     0,  1,  3,  6,  7, -1, -1, -1, -1,
     0,  1,  2,  5,  6,  7, -1, -1, -1,
     0,  1,  2,  3,  5,  6,  7, -1, -1,
     0,  1,  2,  3,  4,  5,  6,  7, -1,
     0,  1,  2,  3,  4,  4,  5,  6,  7,
    -1,  0,  1,  2,  3,  4,  5,  6,  7,
    -1, -1,  0,  1,  2,  4,  5,  6,  7,
    -1, -1, -1,  0,  1,  2,  5,  6,  7,
    -1, -1, -1, -1,  0,  1,  4,  6,  7,
};

/// Compute the height-variant sprite index (0-7) for a tile given its center
/// height `m` and the heights of its lower (`left`) and lower-right (`right`)
/// neighbors. Matches the C++ up-triangle mask formula. Returns 4 (flat) on
/// invalid/edge combinations.
fn heightVariant(m: i32, left: i32, right: i32) u16 {
    const dl = @max(-4, @min(4, m - left));
    const dr = @max(-4, @min(4, m - right));
    const idx: usize = @intCast(4 + dl + 9 * (4 + dr));
    if (idx < 81 and TRI_MASK_UP[idx] >= 0) return @intCast(TRI_MASK_UP[idx]);
    return 4; // fallback: flat-terrain sprite
}

/// Map terrain type + height variant (0-7) to a PAK sprite index.
/// tri_spr[] groups (C++ AssetMapGround, base PAK 260):
///   Water  → offset 32 (PAK 292) — single sprite, variant ignored
///   Grass  → offsets  0-7  (PAK 260-267)
///   Tundra → offsets  8-15 (PAK 268-275)
///   Snow   → offsets 16-23 (PAK 276-283)
///   Desert → offsets 24-31 (PAK 284-291)
fn terrainSpriteId(t: Terrain, variant: u16) ?u16 {
    const base: u16 = switch (t) {
        .water  => return TERRAIN_SPRITE_BASE + 32,
        .grass  => 0,
        .tundra => 8,
        .snow   => 16,
        .desert => 24,
        // Not in original C++ terrain enum — no sprites available.
        .swamp, .lava, .mountain, .mountain2, .mountain_mined, .mountain_flagged => return null,
    };
    return TERRAIN_SPRITE_BASE + base + @min(variant, 7);
}

/// Fallback solid color when no atlas sprite is available.
fn terrainColor(t: Terrain) [4]f32 {
    return switch (t) {
        .water => .{ 0.2, 0.4, 0.8, 1.0 },
        .grass => .{ 0.3, 0.7, 0.2, 1.0 },
        .tundra => .{ 0.5, 0.6, 0.4, 1.0 },
        .snow => .{ 0.9, 0.9, 1.0, 1.0 },
        .swamp => .{ 0.3, 0.4, 0.2, 1.0 },
        .lava => .{ 0.8, 0.3, 0.0, 1.0 },
        .desert => .{ 0.8, 0.7, 0.2, 1.0 },
        .mountain => .{ 0.5, 0.4, 0.3, 1.0 },
        .mountain2 => .{ 0.55, 0.45, 0.35, 1.0 },
        .mountain_mined => .{ 0.6, 0.4, 0.2, 1.0 },
        .mountain_flagged => .{ 0.5, 0.3, 0.1, 1.0 },
    };
}

/// MapRenderer — draws terrain tiles.
pub const MapRenderer = struct {
    shader: Shader = .{},
    vbo: gl.GLuint = 0,
    ibo: gl.GLuint = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
    initialized: bool = false,
    has_atlas: bool = false,

    // x, y, u, v, r, g, b, a
    pub const Vertex = struct {
        x: f32,
        y: f32,
        u: f32,
        v: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    };

    pub fn deinit(self: *MapRenderer) void {
        if (self.vbo != 0) {
            var v = self.vbo;
            gl.deleteBuffers(1, &v);
            self.vbo = 0;
        }
        if (self.ibo != 0) {
            var v = self.ibo;
            gl.deleteBuffers(1, &v);
            self.ibo = 0;
        }
        self.shader.deinit();
        self.initialized = false;
    }

    /// Build/rebuild the VBO. Pass null atlas for colored fallback.
    pub fn init(self: *MapRenderer, map: *Map) !void {
        try self.rebuild(map, null);
        self.shader = try Shader.createDefault();
    }

    /// Rebuild vertex data using atlas UV coordinates.
    pub fn rebuildWithAtlas(self: *MapRenderer, map: *Map, atlas: *TextureAtlas) !void {
        try self.rebuild(map, atlas);
        self.has_atlas = true;
    }

    fn rebuild(self: *MapRenderer, map: *Map, atlas: ?*TextureAtlas) !void {
        if (self.vbo == 0) self.vbo = gl.genBuffers(1);
        if (self.ibo == 0) self.ibo = gl.genBuffers(1);

        const num_tiles = map.tileCount();
        const allocator = std.heap.page_allocator;
        // Each tile = 4 vertices (diamond)
        const vertices = try allocator.alloc(Vertex, num_tiles * 4);
        defer allocator.free(vertices);
        const indices = try allocator.alloc(u16, num_tiles * 6);
        defer allocator.free(indices);

        const hw = TileWidth / 2.0;   // 16 = half diamond width
        const hh = TileHeight;         // 20 = half diamond height (diamond is 32×40)
        // A full Settlers tile forms a diamond from two stacked triangles.
        // The diamond center Y is at: row * TileHeight + TileHeight
        // (top vertex at row*TileHeight, bottom at row*TileHeight+40)

        for (0..map.height) |y| {
            for (0..map.width) |x| {
                const ti = y * map.width + x;
                const tile = map.getTileXY(@intCast(x), @intCast(y));

                // Diamond center in isometric projection (matching C++ map_pix_from_map_coord).
                // mx = 32*col - 16*row, my = 20*row
                // Diamond center is at (mx + hw, my + hh).
                const cx = @as(f32, @floatFromInt(x)) * TileWidth -
                    @as(f32, @floatFromInt(y)) * hw + hw;
                const cy = @as(f32, @floatFromInt(y)) * TileHeight + hh;

                const vi = ti * 4;
                const ii = ti * 6;

                // Compute height-based sprite variant (0-7) using the C++ up-triangle
                // mask formula: variant depends on height differences to lower and
                // lower-right neighbors.
                const m: i32 = @intCast(tile.height);
                const left: i32 = if (y + 1 < map.height)
                    @intCast(map.getTileXY(@intCast(x), @intCast(y + 1)).height)
                else
                    m;
                const right: i32 = if (x + 1 < map.width and y + 1 < map.height)
                    @intCast(map.getTileXY(@intCast(x + 1), @intCast(y + 1)).height)
                else
                    m;
                const variant = heightVariant(m, left, right);

                // UV coordinates
                var u: f32 = 0;
                var v: f32 = 0;
                var uw: f32 = 1;
                var vh: f32 = 1;
                var has_texture = false;
                if (atlas) |a| {
                    if (terrainSpriteId(tile.terrain, variant)) |sid| {
                        if (a.get(sid)) |entry| {
                            u = entry.u;
                            v = entry.v;
                            uw = entry.uw;
                            vh = entry.vh;
                            has_texture = true;
                        }
                    }
                }

                const umid = u + uw / 2.0;
                const vmid = v + vh / 2.0;

                // Color: white when texturing, terrain color for fallback
                const c: [4]f32 = if (has_texture) .{ 1, 1, 1, 1 } else terrainColor(tile.terrain);

                // Diamond quad: 4 vertices forming a diamond shape.
                // Order: top, right, bottom, left (matching sprite_batcher.addTexturedQuad).
                vertices[vi + 0] = .{ .x = cx, .y = cy - hh, .u = umid, .v = v,     .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                vertices[vi + 1] = .{ .x = cx + hw, .y = cy, .u = u + uw, .v = vmid, .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                vertices[vi + 2] = .{ .x = cx, .y = cy + hh, .u = umid, .v = v + vh, .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                vertices[vi + 3] = .{ .x = cx - hw, .y = cy, .u = u,     .v = vmid, .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                // Indices: two triangles (TL->TR->BR) + (TL->BR->BL)
                indices[ii + 0] = @intCast(vi + 0);
                indices[ii + 1] = @intCast(vi + 1);
                indices[ii + 2] = @intCast(vi + 2);
                indices[ii + 3] = @intCast(vi + 0);
                indices[ii + 4] = @intCast(vi + 2);
                indices[ii + 5] = @intCast(vi + 3);
            }
        }

        self.vertex_count = num_tiles * 4;
        self.index_count = num_tiles * 6;

        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(vertices[0..self.vertex_count]), gl.GL_STATIC_DRAW);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);
        gl.bufferData(gl.GL_ELEMENT_ARRAY_BUFFER, std.mem.sliceAsBytes(indices[0..self.index_count]), gl.GL_STATIC_DRAW);
        self.initialized = true;
    }

    pub fn render(self: *MapRenderer, camera: *Camera) void {
        if (!self.initialized) return;
        self.shader.use();
        self.shader.setTexture(0);
        self.shader.setColor(1, 1, 1, 1);
        self.shader.setOffset(0, 0);
        camera.updateMatrices();
        self.shader.setProjection(&camera.projection);
        self.shader.setModelview(&camera.modelview);

        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);
        const stride: i32 = @sizeOf(Vertex);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 8);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 16);
        gl.drawElements(gl.GL_TRIANGLES, @intCast(self.index_count), gl.GL_UNSIGNED_SHORT, 0);
        gl.disableVertexAttribArray(0);
        gl.disableVertexAttribArray(1);
        gl.disableVertexAttribArray(2);
    }
};
