//! Font — bitmap text rendering using sprite batcher.
//!
//! Takes the decoded BitmapFont glyphs from data/font.zig and renders
//! text strings via the SpriteBatcher. Each glyph becomes a textured quad
//! sampled from a glyph texture that we upload once at init.

const std = @import("std");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig").Shader;
const Camera = @import("Camera.zig").Camera;
const Texture = @import("Texture.zig");
const SpriteBatcher = @import("sprite_batcher.zig").SpriteBatcher;

const data = @import("data");
const BitmapFontData = data.font.BitmapFont;

/// Fallback ASCII-only bitmap font for when no game data is loaded.
/// Packed as a 96×14 texture (rows of 16 glyphs, each 6 wide = 96 total width).
pub const GLYPH_W: u8 = 6;
pub const GLYPH_H: u8 = 14;
pub const GLYPHS_PER_ROW: u8 = 16;
pub const FONT_TEXTURE_W: u16 = GLYPH_W * GLYPHS_PER_ROW; // 96
pub const FONT_TEXTURE_H: u16 = GLYPH_H * 6; // 84 (6 rows of 16)
/// Bytes per pixel in the fallback atlas (RGBA8).
const FALLBACK_BPP: usize = 4;

/// Pre-built fallback glyph bitmap (4x6 pixel font rendered as RGBA).
/// Each glyph is GLYPH_W × GLYPH_H pixels.
fn buildFallbackGlyphAtlas() [FONT_TEXTURE_W * FONT_TEXTURE_H * FALLBACK_BPP]u8 {
    // Build a simple 4×6 bitmap font for ASCII 0x20..0x7E.
    // Each glyph in the atlas is 6×14 (the original font size),
    // stored row-first: rows of 16 glyphs.

    @setEvalBranchQuota(50000);

    // We'll build a minimal built-in font bitmap.
    // The font data is packed as 96 glyphs, each 4 pixels wide × 6 pixels tall,
    // then scaled up to GLYPH_W × GLYPH_H in the atlas (the extra columns/rows
    // provide padding between glyphs in screen rendering).
    //
    // For now, return an opaque-white atlas so text is at least visible
    // as white-on-transparent quads. Callers can supply their own font data.
    // RGBA8: every pixel = (255,255,255,255).
    const atlas: [FONT_TEXTURE_W * FONT_TEXTURE_H * FALLBACK_BPP]u8 = @splat(255); // white opaque
    return atlas;
}

/// RGBA pixel data for the font texture (built at comptime).
const FALLBACK_ATLAS: [FONT_TEXTURE_W * FONT_TEXTURE_H * FALLBACK_BPP]u8 = buildFallbackGlyphAtlas();

/// Text alignment.
pub const Align = enum(u2) {
    left,
    center,
    right,
};

/// Font renderer — draws text strings to the screen via SpriteBatcher.
pub const Font = struct {
    /// OpenGL texture ID for the glyph atlas.
    gl_texture: gl.GLuint = 0,
    /// Whether we have a real font loaded from game data.
    has_real_font: bool = false,
    /// The decoded bitmap font (for metrics).
    font_data: BitmapFontData = undefined,
    /// Width of each glyph in the atlas texture.
    glyph_tex_w: f32 = GLYPH_W,
    /// Height of each glyph in the atlas texture.
    glyph_tex_h: f32 = GLYPH_H,
    /// Atlas texture dimensions.
    atlas_w: f32 = FONT_TEXTURE_W,
    atlas_h: f32 = FONT_TEXTURE_H,

    /// Initialize with a fallback built-in font.
    pub fn init(allocator: std.mem.Allocator) !Font {
        const font = Font{
            .font_data = BitmapFontData.init(allocator),
        };
        return font;
    }

    /// Load a real bitmap font from game data and upload to GPU.
    pub fn loadFromData(self: *Font, font_data: *BitmapFontData) !void {
        // Build a texture atlas from the bitmap font glyphs.
        // The original font has 96 glyphs (0x20-0x7F), each ~6×14 pixels.
        // Pack them into a texture: 16 columns × 6 rows.
        const gw = font_data.glyphs[0].width;
        const gh = font_data.glyph_height;
        const cols: u16 = 16;
        const rows: u16 = 6;
        const tw: u16 = @as(u16, gw) * cols;
        const th: u16 = @as(u16, gh) * rows;

        var pixels = try font_data.allocator.alloc(u8, tw * th * 4);
        defer font_data.allocator.free(pixels);
        @memset(pixels, 0);

        for (0..96) |i| {
            const g = &font_data.glyphs[i];
            const col = i % cols;
            const row = i / cols;
            const dx = col * gw;
            const dy = row * gh;
            // Copy glyph pixels (assumed RGBA or grayscale)
            const src_w = @min(g.width, gw);
            const src_h = @min(g.height, gh);
            for (0..src_h) |sy| {
                for (0..src_w) |sx| {
                    const src_i = sy * g.width + sx;
                    const dst_x = dx + sx;
                    const dst_y = dy + sy;
                    const dst_i = (dst_y * tw + dst_x) * 4;
                    // If source is grayscale (1 byte per pixel), replicate to RGB
                    if (g.pixels.len >= (src_w * src_h)) {
                        const v = g.pixels[src_i];
                        pixels[dst_i + 0] = 255;
                        pixels[dst_i + 1] = 255;
                        pixels[dst_i + 2] = 255;
                        pixels[dst_i + 3] = v;
                    } else {
                        pixels[dst_i + 0] = 255;
                        pixels[dst_i + 1] = 255;
                        pixels[dst_i + 2] = 255;
                        pixels[dst_i + 3] = 255;
                    }
                }
            }
        }

        // Upload to GPU
        if (self.gl_texture == 0) {
            self.gl_texture = gl.genTextures(1);
        }
        gl.bindTexture(gl.GL_TEXTURE_2D, self.gl_texture);
        gl.texImage2D(gl.GL_TEXTURE_2D, 0, @intCast(gl.GL_RGBA8), @intCast(tw), @intCast(th), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels.ptr);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

        self.font_data = font_data.*;
        self.glyph_tex_w = @floatFromInt(gw);
        self.glyph_tex_h = @floatFromInt(gh);
        self.atlas_w = @floatFromInt(tw);
        self.atlas_h = @floatFromInt(th);
        self.has_real_font = true;
    }

    /// Upload the built-in fallback font texture to GPU.
    pub fn uploadFallback(self: *Font) void {
        if (self.gl_texture != 0) return;
        self.gl_texture = gl.genTextures(1);
        gl.bindTexture(gl.GL_TEXTURE_2D, self.gl_texture);
        gl.texImage2D(gl.GL_TEXTURE_2D, 0, @intCast(gl.GL_RGBA8), FONT_TEXTURE_W, FONT_TEXTURE_H, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &FALLBACK_ATLAS);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }

    pub fn deinit(self: *Font) void {
        if (self.gl_texture != 0) {
            gl.deleteTextures(1, &self.gl_texture);
            self.gl_texture = 0;
        }
    }

    /// Get the width of a text string in pixels at the given scale.
    pub fn textWidth(self: *Font, text: []const u8, scale: f32) f32 {
        var w: f32 = 0;
        for (text) |char| {
            if (char < 0x20 or char > 0x7E) {
                w += self.glyph_tex_w * scale * 0.5; // space
                continue;
            }
            w += self.glyph_tex_w * scale;
        }
        return w;
    }

    /// Draw a string of text into the sprite batcher.
    /// `x`, `y` is the top-left position in screen coordinates.
    /// `color` is the tint colour (r, g, b, a).
    /// `scale` controls glyph size (1.0 = original pixel size).
    pub fn drawText(self: *Font, batcher: *SpriteBatcher, text: []const u8, x: f32, y: f32, color: [4]f32, scale: f32) void {
        var cx = x;
        const gw = self.glyph_tex_w * scale;
        const gh = self.glyph_tex_h * scale;
        const inv_tw = 1.0 / self.atlas_w;
        const inv_th = 1.0 / self.atlas_h;

        for (text) |char| {
            if (char < 0x20 or char > 0x7E) {
                cx += gw * 0.5; // space
                continue;
            }
            const idx = char - 0x20;
            const col = @as(f32, @floatFromInt(idx % 16));
            const row = @as(f32, @floatFromInt(idx / 16));
            const u = col * self.glyph_tex_w * inv_tw;
            const v = row * self.glyph_tex_h * inv_th;
            const uw = self.glyph_tex_w * inv_tw;
            const vh = self.glyph_tex_h * inv_th;

            batcher.add(.{
                .x = cx,
                .y = y,
                .width = gw,
                .height = gh,
                .u = u,
                .v = v,
                .uw = uw,
                .vh = vh,
                .r = color[0],
                .g = color[1],
                .b = color[2],
                .a = color[3],
            });
            cx += gw;
        }
    }

    /// Draw a right-aligned string into the sprite batcher.
    pub fn drawTextRight(self: *Font, batcher: *SpriteBatcher, text: []const u8, right_x: f32, y: f32, color: [4]f32, scale: f32) void {
        const w = self.textWidth(text, scale);
        self.drawText(batcher, text, right_x - w, y, color, scale);
    }

    /// Draw a centered string into the sprite batcher.
    pub fn drawTextCenter(self: *Font, batcher: *SpriteBatcher, text: []const u8, cx: f32, y: f32, color: [4]f32, scale: f32) void {
        const w = self.textWidth(text, scale);
        self.drawText(batcher, text, cx - w / 2.0, y, color, scale);
    }

    /// Draw a formatted string (std.fmt) into the sprite batcher.
    /// Uses a 256-byte stack buffer for the formatted text.
    pub fn drawFmt(self: *Font, batcher: *SpriteBatcher, comptime fmt: []const u8, args: anytype, x: f32, y: f32, color: [4]f32, scale: f32) void {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.drawText(batcher, text, x, y, color, scale);
    }

    /// Bind the font texture and render batched glyphs.
    pub fn render(self: *Font, batcher: *SpriteBatcher, shader: *Shader, camera: *Camera) void {
        if (self.gl_texture == 0) return;
        var tex = Texture{ .id = self.gl_texture, .width = @intFromFloat(self.atlas_w), .height = @intFromFloat(self.atlas_h) };
        batcher.render(shader, &tex, camera);
    }
};