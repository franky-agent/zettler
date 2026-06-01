//! Map renderer — renders the hex grid terrain with textured quads.
//!
//! Each terrain tile is drawn as a diamond (like the original Settlers).
//! Uses the original Settlers isometric coordinate projection:
//!   screen_x = col * TileWidth  - row * (TileWidth/2)
//!   screen_y = row * TileHeight
//!
//! In the original C++ code, terrain sprites (AssetMapGround) are fully
//! opaque solid rectangles (SpriteTypeSolid). The diamond shape comes from
//! a separate mask system (AssetMapMaskUp/AssetMapMaskDown) that clips each
//! rectangular sprite to a triangle. Here we replicate that effect by
//! rendering each tile as two explicit triangles with axis-aligned UV
//! coordinates, so the sprite content maps correctly without a mask texture.

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

/// The flat (level-ground) sprite variant. One uniform sprite per terrain type;
/// relief is conveyed by per-vertex shading, not by per-tile slope sprites.
const FLAT_VARIANT: u16 = 4;

/// Map terrain type to its flat (variant 4) ground sprite PAK index. Terrain is
/// drawn with one uniform sprite per type; relief comes from per-vertex shading.
/// tri_spr[] groups (C++ AssetMapGround, base PAK 260): Grass 260-267,
/// Tundra 268-275, Snow 276-283, Desert 284-291; Water uses offset 32 (PAK 292).
fn terrainSpriteId(t: Terrain) ?u16 {
    const base: u16 = switch (t) {
        .water  => return TERRAIN_SPRITE_BASE + 32,
        .grass  => 0,
        .tundra => 8,
        .snow   => 16,
        .desert => 24,
        // Not in original C++ terrain enum — no sprites available.
        .swamp, .lava, .mountain, .mountain2, .mountain_mined, .mountain_flagged => return null,
    };
    return TERRAIN_SPRITE_BASE + base + FLAT_VARIANT;
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

/// Vertical screen offset per unit of terrain height (original game: 4 px).
/// This is what produces the fake-2.5D relief: a vertex sitting on a tall tile
/// is pushed up the screen, so hills rise and valleys sink.
pub const HEIGHT_SCALE: f32 = 4.0;

/// Height (in tile units) at a map position, clamped to the map bounds so edge
/// tiles reuse the nearest in-bounds height instead of reading out of range.
fn heightAt(map: *Map, x: usize, y: usize) f32 {
    const xx: u16 = @intCast(@min(x, @as(usize, map.width) - 1));
    const yy: u16 = @intCast(@min(y, @as(usize, map.height) - 1));
    return @floatFromInt(map.getTileXY(xx, yy).height);
}

// Directional-light shading constants. Light from the upper-left.
const SHADE_AMBIENT: f32 = 0.92;
const SHADE_DIFFUSE: f32 = 0.13;
const SHADE_LX: f32 = 1.0;
const SHADE_LY: f32 = 1.0;
const SHADE_MIN: f32 = 0.6;
const SHADE_MAX: f32 = 1.25;

/// Per-vertex brightness multiplier from the local height gradient (slope) dotted
/// with a fixed light direction. Flat ground → ~SHADE_AMBIENT; slopes facing the
/// light brighten, slopes facing away darken — the shaded-relief effect.
fn shadeAt(map: *Map, x: usize, y: usize) f32 {
    const xl = if (x > 0) x - 1 else x;
    const yu = if (y > 0) y - 1 else y;
    const dhx = heightAt(map, x + 1, y) - heightAt(map, xl, y);
    const dhy = heightAt(map, x, y + 1) - heightAt(map, x, yu);
    const ndl = SHADE_LX * (-dhx) + SHADE_LY * (-dhy);
    return @max(SHADE_MIN, @min(SHADE_MAX, SHADE_AMBIENT + SHADE_DIFFUSE * ndl));
}

/// Per-vertex tint (v_color.rgb). The shader does `mix(tint, px*tint, ca)`, so for
/// a textured tile (ca=1) the tint is the brightness applied to the sprite → grey
/// `(s,s,s)`; for a sprite-less tile (water, ca=0) the tint is the flat fallback
/// colour scaled by the brightness.
fn cornerTint(fb: [4]f32, ca: f32, s: f32) [3]f32 {
    if (ca > 0.5) return .{ s, s, s };
    return .{ fb[0] * s, fb[1] * s, fb[2] * s };
}

/// True if tile (x,y) borders a tile of a different terrain type (any of the 8
/// neighbours). Such tiles get the dithered overlay so transitions are stippled;
/// interior uniform tiles render only the clean solid base.
fn isTerrainBoundary(map: *Map, x: usize, y: usize) bool {
    const t = map.getTileXY(@intCast(x), @intCast(y)).terrain;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            const nx = @as(i32, @intCast(x)) + dx;
            const ny = @as(i32, @intCast(y)) + dy;
            if (nx < 0 or ny < 0 or nx >= map.width or ny >= map.height) continue;
            if (map.getTileXY(@intCast(nx), @intCast(ny)).terrain != t) return true;
        }
    }
    return false;
}

/// Build a terrain vertex. `(gu,gv)` is the screen-space ground-local UV (x/32,
/// y/20) so the flat ground texture tiles seamlessly across the map.
/// (ba,bb) are barycentric (overlay edge-fade); (r,g,b) is the brightness tint.
fn mkVert(x: f32, y: f32, gu: f32, gv: f32, eu: f32, ev: f32, euw: f32, evh: f32,
    ba: f32, bb: f32, r: f32, g: f32, b: f32, a: f32) MapRenderer.Vertex {
    return .{
        .x = x, .y = y,
        .gl_u = gu, .gl_v = gv,
        .gr_u = eu, .gr_v = ev, .gr_uw = euw, .gr_vh = evh,
        .m_u = ba, .m_v = bb, .r = r, .g = g, .b = b, .a = a,
    };
}

/// Emit one overlay triangle (3 verts, 3 indices): the triangle A,B,C expanded
/// from its centroid by `expand` (so it bleeds into neighbours) and tagged with
/// barycentric coords A=(1,0) B=(0,1) C=(0,0) for the shader's edge-fade dither.
/// Ground UV is screen-space so the overlay tiles like the base.
fn emitTri(verts: []MapRenderer.Vertex, idx: []u16, base: u16,
    ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, expand: f32,
    eu: f32, ev: f32, euw: f32, evh: f32,
    c0: [3]f32, c1: [3]f32, c2: [3]f32, a: f32) void {
    const gx = (ax + bx + cx) / 3.0;
    const gy = (ay + by + cy) / 3.0;
    const x0 = gx + (ax - gx) * expand; const y0 = gy + (ay - gy) * expand;
    const x1 = gx + (bx - gx) * expand; const y1 = gy + (by - gy) * expand;
    const x2 = gx + (cx - gx) * expand; const y2 = gy + (cy - gy) * expand;
    // Per-vertex tint (c0,c1,c2) so the overlay shades smoothly like the base,
    // instead of a flat single-brightness triangle.
    verts[0] = mkVert(x0, y0, x0 / TileWidth, y0 / TileHeight, eu, ev, euw, evh, 1, 0, c0[0], c0[1], c0[2], a);
    verts[1] = mkVert(x1, y1, x1 / TileWidth, y1 / TileHeight, eu, ev, euw, evh, 0, 1, c1[0], c1[1], c1[2], a);
    verts[2] = mkVert(x2, y2, x2 / TileWidth, y2 / TileHeight, eu, ev, euw, evh, 0, 0, c2[0], c2[1], c2[2], a);
    idx[0] = base + 0;
    idx[1] = base + 1;
    idx[2] = base + 2;
}

/// MapRenderer — draws terrain tiles.
pub const MapRenderer = struct {
    shader: Shader = .{},
    vbo: gl.GLuint = 0,           // base pass: clean gap-free parallelograms (all tiles)
    ibo: gl.GLuint = 0,
    overlay_vbo: gl.GLuint = 0,   // overlay pass: expanded dithered triangles (boundary tiles)
    overlay_ibo: gl.GLuint = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
    overlay_vertex_count: usize = 0,
    overlay_index_count: usize = 0,
    initialized: bool = false,
    has_atlas: bool = false,

    // Terrain vertex (matches Shader.createMaskedTerrain):
    //   position(x,y), ground_local(gl_u,gl_v), ground_region(gr_*),
    //   bary(m_u,m_v) — vertex barycentric for the overlay edge-fade,
    //   color(r,g,b,a) — fallback colour (a=0) or sprite tint (a=1).
    pub const Vertex = struct {
        x: f32,
        y: f32,
        gl_u: f32,
        gl_v: f32,
        gr_u: f32,
        gr_v: f32,
        gr_uw: f32,
        gr_vh: f32,
        m_u: f32, // barycentric a
        m_v: f32, // barycentric b
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
        if (self.overlay_vbo != 0) {
            var v = self.overlay_vbo;
            gl.deleteBuffers(1, &v);
            self.overlay_vbo = 0;
        }
        if (self.overlay_ibo != 0) {
            var v = self.overlay_ibo;
            gl.deleteBuffers(1, &v);
            self.overlay_ibo = 0;
        }
        self.shader.deinit();
        self.initialized = false;
    }

    /// Build/rebuild the VBO. Pass null atlas for colored fallback.
    pub fn init(self: *MapRenderer, map: *Map) !void {
        try self.rebuild(map, null);
        self.shader = try Shader.createMaskedTerrain();
    }

    /// Rebuild vertex data using atlas UV coordinates.
    pub fn rebuildWithAtlas(self: *MapRenderer, map: *Map, atlas: *TextureAtlas) !void {
        try self.rebuild(map, atlas);
        self.has_atlas = true;
    }

    fn rebuild(self: *MapRenderer, map: *Map, atlas: ?*TextureAtlas) !void {
        if (self.vbo == 0) self.vbo = gl.genBuffers(1);
        if (self.ibo == 0) self.ibo = gl.genBuffers(1);
        if (self.overlay_vbo == 0) self.overlay_vbo = gl.genBuffers(1);
        if (self.overlay_ibo == 0) self.overlay_ibo = gl.genBuffers(1);

        const num_tiles = map.tileCount();
        const allocator = std.heap.page_allocator;
        // BASE: every tile is a clean, gap-free parallelogram (4 verts P,R,Dn,DR +
        // 6 indices), each terrain solid → crisp diagonal terrain boundaries, no
        // overlap, no holes.
        // OVERLAY: only boundary tiles, their two triangles slightly EXPANDED so
        // they bleed into the neighbour, carrying barycentric coords. The shader
        // fades each triangle out toward its rim with an ordered dither, revealing
        // the base (neighbour) behind → a clean procedural stippled transition.
        const base_v = try allocator.alloc(Vertex, num_tiles * 4);
        defer allocator.free(base_v);
        const base_i = try allocator.alloc(u16, num_tiles * 6);
        defer allocator.free(base_i);
        const ov_v = try allocator.alloc(Vertex, num_tiles * 6);
        defer allocator.free(ov_v);
        const ov_i = try allocator.alloc(u16, num_tiles * 6);
        defer allocator.free(ov_i);
        var ov_vc: usize = 0; // overlay vertex count
        var ov_ic: usize = 0; // overlay index count

        const hw = TileWidth / 2.0; // 16
        const EXPAND: f32 = 1.7; // how far overlay triangles bleed into neighbours
        // (wider bleed + smoothstep density ramp in the shader = a gradual,
        //  smooth dithered dissolve at terrain boundaries, like the C# masks).

        for (0..map.height) |y| {
            for (0..map.width) |x| {
                const ti = y * map.width + x;

                const lx = @as(f32, @floatFromInt(x)) * TileWidth -
                    @as(f32, @floatFromInt(y)) * hw;
                const ly = @as(f32, @floatFromInt(y)) * TileHeight;

                const tile = map.getTileXY(@intCast(x), @intCast(y));

                // Per-vertex 2.5D relief from the four rhombus grid heights.
                const hP = HEIGHT_SCALE * heightAt(map, x, y);
                const hR = HEIGHT_SCALE * heightAt(map, x + 1, y);
                const hDn = HEIGHT_SCALE * heightAt(map, x, y + 1);
                const hDR = HEIGHT_SCALE * heightAt(map, x + 1, y + 1);

                // Rhombus corners (screen space):
                const Px = lx;             const Py = ly - hP;
                const Rx = lx + TileWidth; const Ry = ly - hR;
                const Dx = lx - hw;        const Dy = ly + TileHeight - hDn; // Dn
                const Qx = lx + hw;        const Qy = ly + TileHeight - hDR; // DR

                // Flat ground sprite (one per terrain); relief comes from shading.
                var eu: f32 = 0; var ev: f32 = 0; var euw: f32 = 0; var evh: f32 = 0;
                var ca: f32 = 0;
                if (atlas) |a| {
                    if (terrainSpriteId(tile.terrain)) |sid| {
                        if (a.get(sid)) |e| { eu = e.u; ev = e.v; euw = e.uw; evh = e.vh; ca = 1; }
                    }
                }
                const fb = terrainColor(tile.terrain);

                // Per-corner brightness from the height slope; tint per corner:
                // textured → (s,s,s); water (no sprite) → fallback*s.
                const cP = cornerTint(fb, ca, shadeAt(map, x, y));
                const cR = cornerTint(fb, ca, shadeAt(map, x + 1, y));
                const cDn = cornerTint(fb, ca, shadeAt(map, x, y + 1));
                const cDR = cornerTint(fb, ca, shadeAt(map, x + 1, y + 1));

                // ── BASE parallelogram: verts P,R,Dn,DR; UP=(P,Dn,DR) DOWN=(P,R,DR).
                // Ground UV is screen-space (x/32, y/20) so the flat sprite tiles
                // seamlessly via the shader's fract().
                const bvi = ti * 4;
                const bii = ti * 6;
                base_v[bvi + 0] = mkVert(Px, Py, Px / TileWidth, Py / TileHeight, eu, ev, euw, evh, 0, 0, cP[0], cP[1], cP[2], ca); // P
                base_v[bvi + 1] = mkVert(Rx, Ry, Rx / TileWidth, Ry / TileHeight, eu, ev, euw, evh, 0, 0, cR[0], cR[1], cR[2], ca); // R
                base_v[bvi + 2] = mkVert(Dx, Dy, Dx / TileWidth, Dy / TileHeight, eu, ev, euw, evh, 0, 0, cDn[0], cDn[1], cDn[2], ca); // Dn
                base_v[bvi + 3] = mkVert(Qx, Qy, Qx / TileWidth, Qy / TileHeight, eu, ev, euw, evh, 0, 0, cDR[0], cDR[1], cDR[2], ca); // DR
                base_i[bii + 0] = @intCast(bvi + 0); // UP: P
                base_i[bii + 1] = @intCast(bvi + 2); //     Dn
                base_i[bii + 2] = @intCast(bvi + 3); //     DR
                base_i[bii + 3] = @intCast(bvi + 0); // DOWN: P
                base_i[bii + 4] = @intCast(bvi + 1); //       R
                base_i[bii + 5] = @intCast(bvi + 3); //       DR

                // ── OVERLAY: only boundary tiles get the dithered transition ──
                // The overlay always uses the flat variant + screen-space UV; its tint
                // is the apex-corner colour so it matches the base near that vertex.
                if (isTerrainBoundary(map, x, y)) {
                    var ou: f32 = 0; var ov: f32 = 0; var ouw: f32 = 0; var ovh: f32 = 0;
                    if (atlas) |a| {
                        if (terrainSpriteId(tile.terrain)) |sid| {
                            if (a.get(sid)) |e| { ou = e.u; ov = e.v; ouw = e.uw; ovh = e.vh; }
                        }
                    }
                    // UP triangle P,Dn,DR → per-vertex tints cP,cDn,cDR.
                    emitTri(ov_v[ov_vc .. ov_vc + 3], ov_i[ov_ic .. ov_ic + 3], @intCast(ov_vc),
                        Px, Py, Dx, Dy, Qx, Qy, EXPAND, ou, ov, ouw, ovh, cP, cDn, cDR, ca);
                    ov_vc += 3; ov_ic += 3;
                    // DOWN triangle P,R,DR → per-vertex tints cP,cR,cDR.
                    emitTri(ov_v[ov_vc .. ov_vc + 3], ov_i[ov_ic .. ov_ic + 3], @intCast(ov_vc),
                        Px, Py, Rx, Ry, Qx, Qy, EXPAND, ou, ov, ouw, ovh, cP, cR, cDR, ca);
                    ov_vc += 3; ov_ic += 3;
                }
            }
        }

        self.vertex_count = num_tiles * 4;
        self.index_count = num_tiles * 6;
        self.overlay_vertex_count = ov_vc;
        self.overlay_index_count = ov_ic;

        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(base_v[0..self.vertex_count]), gl.GL_STATIC_DRAW);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);
        gl.bufferData(gl.GL_ELEMENT_ARRAY_BUFFER, std.mem.sliceAsBytes(base_i[0..self.index_count]), gl.GL_STATIC_DRAW);
        if (ov_vc > 0) {
            gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.overlay_vbo);
            gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(ov_v[0..ov_vc]), gl.GL_STATIC_DRAW);
            gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.overlay_ibo);
            gl.bufferData(gl.GL_ELEMENT_ARRAY_BUFFER, std.mem.sliceAsBytes(ov_i[0..ov_ic]), gl.GL_STATIC_DRAW);
        }
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

        // Layout: pos(0) ground_local(8) ground_region(16) bary(32) color(40)
        // 14 floats = 56 bytes.
        const stride: i32 = @sizeOf(Vertex);

        // Pass 1: clean solid base over ALL tiles (crisp diagonal boundaries).
        self.shader.setUseMask(0);
        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        bindTerrainAttribs(stride);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);
        gl.drawElements(gl.GL_TRIANGLES, @intCast(self.index_count), gl.GL_UNSIGNED_SHORT, 0);

        // Pass 2: procedurally-dithered overlay over BOUNDARY tiles only. The
        // expanded triangles bleed into neighbours and the shader fades them out
        // with an ordered dither, revealing the base → clean stippled transitions.
        if (self.overlay_index_count > 0) {
            self.shader.setUseMask(1);
            gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.overlay_vbo);
            bindTerrainAttribs(stride);
            gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.overlay_ibo);
            gl.drawElements(gl.GL_TRIANGLES, @intCast(self.overlay_index_count), gl.GL_UNSIGNED_SHORT, 0);
        }

        gl.disableVertexAttribArray(0);
        gl.disableVertexAttribArray(1);
        gl.disableVertexAttribArray(2);
        gl.disableVertexAttribArray(3);
        gl.disableVertexAttribArray(4);
    }
};

/// Set up the terrain vertex attribute pointers against the currently-bound VBO.
fn bindTerrainAttribs(stride: i32) void {
    gl.enableVertexAttribArray(0); // a_position
    gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 0);
    gl.enableVertexAttribArray(1); // a_ground_local
    gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 8);
    gl.enableVertexAttribArray(2); // a_ground_region
    gl.vertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 16);
    gl.enableVertexAttribArray(3); // a_bary
    gl.vertexAttribPointer(3, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 32);
    gl.enableVertexAttribArray(4); // a_color
    gl.vertexAttribPointer(4, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 40);
}
