//! Texture — OpenGL texture management.
//!
//! Handles uploading sprite pixel data to the GPU,
//! managing texture atlases, and texture caching.

const std = @import("std");
const gl = @import("gl.zig");

/// An OpenGL texture object.
pub const Texture = struct {
    /// OpenGL texture ID.
    id: gl.GLuint = 0,
    /// Width of the texture in pixels.
    width: u32 = 0,
    /// Height of the texture in pixels.
    height: u32 = 0,

    /// Create a texture from RGBA pixel data.
    pub fn init(pixels: []const u8, w: u32, h: u32) Texture {
        const tex_id = gl.genTextures(1);
        gl.bindTexture(gl.GL_TEXTURE_2D, tex_id);

        // Upload pixel data
        gl.texImage2D(
            gl.GL_TEXTURE_2D,
            0, @intCast(gl.GL_RGBA8),
            @intCast(w), @intCast(h),
            gl.GL_RGBA, gl.GL_UNSIGNED_BYTE,
            pixels.ptr,
        );

        // Set filtering (bilinear for smooth scaling)
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

        return .{
            .id = tex_id,
            .width = w,
            .height = h,
        };
    }

    pub fn deinit(self: *Texture) void {
        if (self.id != 0) {
            const ids = [_]gl.GLuint{self.id};
            gl.deleteTextures(1, &ids);
            self.id = 0;
        }
    }

    /// Bind this texture for rendering.
    pub fn bind(self: *Texture) void {
        gl.bindTexture(gl.GL_TEXTURE_2D, self.id);
    }

    /// Get normalized texture coordinates (u, v, w, h) for a sub-rectangle.
    pub fn getSubTexCoords(self: Texture, x: u32, y: u32, w: u32, h: u32) struct { u: f32, v: f32, uw: f32, vh: f32 } {
        return .{
            .u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width)),
            .v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height)),
            .uw = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(self.width)),
            .vh = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(self.height)),
        };
    }
};
