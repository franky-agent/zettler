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
};

/// Maximum number of sprites that can be packed into the atlas.
pub const MAX_ATLAS_SPRITES: usize = 4096;
/// Atlas size (power of two).
pub const ATLAS_SIZE: u32 = 2048;
/// Margin between sprites in the atlas (to avoid bleeding).
pub const ATLAS_MARGIN: u32 = 1;

/// Texture atlas — builds and manages a single large texture containing many sprites.
pub const TextureAtlas = struct {
    allocator: std.mem.Allocator,
    gl_texture: gl.GLuint = 0,
    pixels: []ColorRGBA = &.{},
    cursor_x: u32 = ATLAS_MARGIN,
    cursor_y: u32 = ATLAS_MARGIN,
    row_height: u32 = 0,
    entries: std.AutoHashMap(u16, AtlasEntry),
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
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .entries = std.AutoHashMap(u16, AtlasEntry).init(allocator),
        };
    }

    pub fn deinit(self: *TextureAtlas) void {
        if (self.gl_texture != 0) {
            var tex = self.gl_texture;
            gl.deleteTextures(1, &tex);
        }
        self.allocator.free(self.pixels);
        self.entries.deinit();
    }

    pub fn packSprite(self: *TextureAtlas, sprite_id: u16, sprite: *const Sprite) !AtlasEntry {
        if (self.entries.contains(sprite_id)) return self.entries.get(sprite_id).?;
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

        for (0..h) |sy| {
            for (0..w) |sx| {
                self.pixels[(self.cursor_y + ATLAS_MARGIN + sy) * ATLAS_SIZE + (self.cursor_x + ATLAS_MARGIN + sx)] =
                    sprite.pixels[sy * w + sx];
            }
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
        };
        try self.entries.put(sprite_id, entry);
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

    pub fn get(self: *TextureAtlas, sprite_id: u16) ?AtlasEntry { return self.entries.get(sprite_id); }
    pub fn has(self: *TextureAtlas, sprite_id: u16) bool { return self.entries.contains(sprite_id); }
    pub fn count(self: TextureAtlas) usize { return self.entries.count(); }

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
