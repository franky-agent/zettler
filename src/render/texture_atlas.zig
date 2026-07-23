//! Texture atlas — packs decoded sprites from game data into OpenGL textures.
//!
//! Loads sprites from the SPAE.PA archive through the TPWM → PAK → BMP pipeline,
//! packs them into a power-of-two atlas texture, and uploads to the GPU.
//! Provides sprite ID → UV coordinate mapping for the sprite batcher.

const std = @import("std");
const gl = @import("gl.zig");
const data = @import("data");

const PakFile = data.PakFile;
const Sprite = data.Sprite;
const BmpDecoder = data.BmpDecoder;
const ColorRGBA = data.ColorRGBA;

/// A single atlas entry mapping a sprite ID to its UV rect.
pub const AtlasEntry = struct {
    u: f32, v: f32,
    uw: f32, vh: f32,
    pixel_w: u32, pixel_h: u32,
    atlas_x: u32, atlas_y: u32,
    off_x: i16 = 0, off_y: i16 = 0, // sprite hotspot offset (needed for masks)
};

/// Maximum number of sprites that can be packed into the atlas.
pub const MAX_ATLAS_SPRITES: usize = 4096;
/// Atlas size (power of two).
pub const ATLAS_SIZE: u32 = 2048;
/// Margin between sprites in the atlas (to avoid bleeding).
pub const ATLAS_MARGIN: u32 = 1;

/// Size of the direct lookup table indexed by sprite ID. Covers all sprite
/// IDs used by the game (terrain ≤ 292, waves ≤ 645, buildings/shadows
/// ≤ MAP_OBJECT_BASE + 0xc0 + 250 ≈ 1700). Sized to 4096 to match
/// MAX_ATLAS_SPRITES and leave headroom for future sprite ranges.
const LOOKUP_TABLE_SIZE: usize = 4096;

/// Texture atlas — builds and manages a single large texture containing many sprites.
pub const TextureAtlas = struct {
    allocator: std.mem.Allocator,
    gl_texture: gl.GLuint = 0,
    pixels: []ColorRGBA = &.{},
    cursor_x: u32 = ATLAS_MARGIN,
    cursor_y: u32 = ATLAS_MARGIN,
    row_height: u32 = 0,
    /// Direct-index lookup table: entries[sprite_id] == null means not packed.
    /// Replaces a std.AutoHashMap — sprite IDs are dense u16 indices, so a
    /// flat array turns every get()/has() from a hash+probe into one indexed
    /// load (~15% of frame time was spent in wyhash on the old HashMap).
    entries: []?AtlasEntry = &.{},
    uploaded: bool = false,
    packed_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !TextureAtlas {
        const pixels = try allocator.alloc(ColorRGBA, ATLAS_SIZE * ATLAS_SIZE);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        // Set pixel (0,0) to white for fallback rendering.
        // Tiles without valid sprite sprites use zero-area UV at (0,0)
        // and the shader does tex * v_color, so sampling white yields
        // the vertex color unchanged.
        pixels[0] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const entries = try allocator.alloc(?AtlasEntry, LOOKUP_TABLE_SIZE);
        @memset(entries, null);
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .entries = entries,
        };
    }

    pub fn deinit(self: *TextureAtlas) void {
        if (self.gl_texture != 0) {
            var tex = self.gl_texture;
            gl.deleteTextures(1, &tex);
        }
        self.allocator.free(self.pixels);
        self.allocator.free(self.entries);
    }

    pub fn packSprite(self: *TextureAtlas, sprite_id: u16, sprite: *const Sprite) !AtlasEntry {
        if (sprite_id >= self.entries.len) return error.SpriteIdOutOfRange;
        if (self.entries[sprite_id]) |existing| return existing;
        if (self.packed_count >= MAX_ATLAS_SPRITES) return error.AtlasFull;

        const w = sprite.width;
        const h = sprite.height;
        const pw = w + ATLAS_MARGIN * 2;
        const ph = h + ATLAS_MARGIN * 2;

        if (self.cursor_x + pw > ATLAS_SIZE) {
            self.cursor_x = ATLAS_MARGIN;
            self.cursor_y += self.row_height + ATLAS_MARGIN;
            self.row_height = 0;
        }
        if (self.cursor_y + ph > ATLAS_SIZE) return error.AtlasFull;

        const base_x = self.cursor_x + ATLAS_MARGIN;
        const base_y = self.cursor_y + ATLAS_MARGIN;
        for (0..h) |sy| {
            for (0..w) |sx| {
                self.pixels[(base_y + sy) * ATLAS_SIZE + (base_x + sx)] =
                    sprite.pixels[sy * w + sx];
            }
        }

        // Edge-replication padding into the 1px margin. With GL_LINEAR sampling,
        // a fragment near a sprite edge would otherwise blend into the neighbor
        // sprite (or transparent margin) and show a dark seam. Copying the border
        // pixels outward makes the blend sample a duplicate of the edge instead.
        if (w > 0 and h > 0) {
            for (0..h) |sy| {
                const row = base_y + sy;
                self.pixels[row * ATLAS_SIZE + (base_x - 1)] = sprite.pixels[sy * w + 0];
                self.pixels[row * ATLAS_SIZE + (base_x + w)] = sprite.pixels[sy * w + (w - 1)];
            }
            for (0..w) |sx| {
                const col = base_x + sx;
                self.pixels[(base_y - 1) * ATLAS_SIZE + col] = sprite.pixels[0 * w + sx];
                self.pixels[(base_y + h) * ATLAS_SIZE + col] = sprite.pixels[(h - 1) * w + sx];
            }
            self.pixels[(base_y - 1) * ATLAS_SIZE + (base_x - 1)] = sprite.pixels[0];
            self.pixels[(base_y - 1) * ATLAS_SIZE + (base_x + w)] = sprite.pixels[w - 1];
            self.pixels[(base_y + h) * ATLAS_SIZE + (base_x - 1)] = sprite.pixels[(h - 1) * w + 0];
            self.pixels[(base_y + h) * ATLAS_SIZE + (base_x + w)] = sprite.pixels[(h - 1) * w + (w - 1)];
        }
        self.row_height = @max(self.row_height, ph);

        const fs: f32 = @floatFromInt(ATLAS_SIZE);
        const entry = AtlasEntry{
            .u = @as(f32, @floatFromInt(self.cursor_x + ATLAS_MARGIN)) / fs,
            .v = @as(f32, @floatFromInt(self.cursor_y + ATLAS_MARGIN)) / fs,
            .uw = @as(f32, @floatFromInt(w)) / fs,
            .vh = @as(f32, @floatFromInt(h)) / fs,
            .pixel_w = w, .pixel_h = h,
            .atlas_x = self.cursor_x, .atlas_y = self.cursor_y,
            .off_x = sprite.offset_x, .off_y = sprite.offset_y,
        };
        self.entries[sprite_id] = entry;
        self.cursor_x += pw;
        self.packed_count += 1;
        return entry;
    }

    pub fn upload(self: *TextureAtlas) !void {
        if (self.uploaded) return;
        if (self.gl_texture != 0) { var t = self.gl_texture; gl.deleteTextures(1, &t); }
        self.gl_texture = gl.genTextures(1);
        gl.bindTexture(gl.GL_TEXTURE_2D, self.gl_texture);
        gl.texImage2D(gl.GL_TEXTURE_2D, 0, @intCast(gl.GL_RGBA8),
            @intCast(ATLAS_SIZE), @intCast(ATLAS_SIZE),
            gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, @ptrCast(self.pixels.ptr));
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        self.uploaded = true;
    }

    pub fn bind(self: *TextureAtlas) void {
        if (self.gl_texture != 0) gl.bindTexture(gl.GL_TEXTURE_2D, self.gl_texture);
    }

    /// Switch the atlas sampling filter. Terrain uses linear (smooth tile edges);
    /// sprites/UI use nearest (crisp pixel art). Binds the atlas as a side effect.
    pub fn setFilter(self: *TextureAtlas, linear: bool) void {
        if (self.gl_texture == 0) return;
        gl.bindTexture(gl.GL_TEXTURE_2D, self.gl_texture);
        const f: gl.GLint = if (linear) @intCast(gl.GL_LINEAR) else @intCast(gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, f);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, f);
    }

    pub fn get(self: *TextureAtlas, sprite_id: u16) ?AtlasEntry {
        if (sprite_id >= self.entries.len) return null;
        return self.entries[sprite_id];
    }

    pub fn has(self: *TextureAtlas, sprite_id: u16) bool {
        if (sprite_id >= self.entries.len) return false;
        return self.entries[sprite_id] != null;
    }
    pub fn count(self: TextureAtlas) usize { return self.packed_count; }

    /// Load terrain tiles from PAK and pack into atlas.
    pub fn loadTerrainSprites(self: *TextureAtlas, pak: *PakFile, decoder: *BmpDecoder) !void {
        const ids = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        for (ids) |id| {
            const raw = try pak.getFile(id);
            var sprite = try decoder.decode(raw);
            defer sprite.deinit(self.allocator);
            try self.packSprite(id, &sprite);
        }
    }

    /// Load building sprites from PAK for given sprite IDs.
    pub fn loadBuildingSprites(self: *TextureAtlas, pak: *const PakFile, decoder: *BmpDecoder, ids: []const u16) !void {
        for (ids) |id| {
            if (id >= pak.fileCount()) continue;
            const raw = pak.getFile(id) catch continue;
            var sprite = decoder.decode(raw) catch continue;
            defer sprite.deinit(self.allocator);
            _ = try self.packSprite(id, &sprite);
        }
    }

    /// Load OVERLAY (shadow) sprites from PAK for given sprite IDs, decoded as
    /// semi-transparent shadow stencils (AssetMapShadow / AssetSerfShadow).
    pub fn loadOverlaySprites(self: *TextureAtlas, pak: *const PakFile, decoder: *BmpDecoder, ids: []const u16) !void {
        for (ids) |id| {
            if (id >= pak.fileCount()) continue;
            const raw = pak.getFile(id) catch continue;
            var sprite = decoder.decodeOverlay(raw) catch continue;
            defer sprite.deinit(self.allocator);
            _ = try self.packSprite(id, &sprite);
        }
    }

    /// Load a range of sprites.
    pub fn loadRange(self: *TextureAtlas, pak: *const PakFile, decoder: *BmpDecoder, start: u16, end: u16) !void {
        var i = start;
        while (i < end and i < pak.fileCount()) : (i += 1) {
            const raw = pak.getFile(i) catch continue;
            var sprite = decoder.decode(raw) catch continue;
            defer sprite.deinit(self.allocator);
            _ = try self.packSprite(i, &sprite);
        }
    }
};
