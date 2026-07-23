//! Camera — 2D camera / viewport management.
//!
//! Handles scrolling, zooming, and map-to-screen coordinate transforms.
//! The game uses a 2D orthographic camera that scrolls around the hex grid.
//! Supports torus wrapping: the camera position wraps within map bounds
//! so the world appears seamlessly infinite.

const std = @import("std");
const gl = @import("gl.zig");
const core = @import("core");

const Vec2f = core.Vec2f;
const Mat4 = core.Mat4;

/// 2D camera for the game.
pub const Camera = struct {
    /// Camera position in world space (tiles).
    x: f32 = 0,
    y: f32 = 0,
    /// Zoom level (1.0 = normal).
    zoom: f32 = 1.0,
    /// Viewport size in pixels.
    viewport_w: f32 = 800,
    viewport_h: f32 = 600,
    /// Scroll speed in tiles per second.
    scroll_speed: f32 = 500.0,

    // Pre-computed matrices
    projection: [16]f32 = undefined,
    modelview: [16]f32 = undefined,
    matrices_dirty: bool = true,

    /// Set the viewport size.
    pub fn setViewportSize(self: *Camera, w: f32, h: f32) void {
        self.viewport_w = w;
        self.viewport_h = h;
        self.matrices_dirty = true;
    }

    /// Update projection and modelview matrices.
    pub fn updateMatrices(self: *Camera) void {
        if (!self.matrices_dirty) return;

        // Orthographic projection (left, right, bottom, top)
        const half_w = self.viewport_w / (2.0 * self.zoom);
        const half_h = self.viewport_h / (2.0 * self.zoom);
        const left = -half_w;
        const right = half_w;
        const bottom = -half_h;
        const top = half_h;

        // Y-down: swap bottom/top so world y increases downward, matching tile coords
        self.projection = Mat4.ortho(left, right, top, bottom, -1, 1).data;

        // Modelview: translate by camera position
        var mv: Mat4 = .{};
        mv.data[12] = -self.x;
        mv.data[13] = -self.y;
        self.modelview = mv.data;

        self.matrices_dirty = false;
    }

    /// Convert screen coordinates to world coordinates.
    pub fn screenToWorld(self: Camera, screen_x: f32, screen_y: f32) Vec2f {
        const wx = (screen_x - self.viewport_w / 2.0) / self.zoom + self.x;
        const wy = (screen_y - self.viewport_h / 2.0) / self.zoom + self.y;
        return .{ .x = wx, .y = wy };
    }

    /// Returns the world-space rectangle visible through this camera as
    /// `(min_x, min_y, max_x, max_y)`. Used for viewport culling: only tiles
    /// whose world position falls inside this rectangle can be on screen.
    pub fn visibleWorldBounds(self: Camera) struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 } {
        const half_w = self.viewport_w / (2.0 * self.zoom);
        const half_h = self.viewport_h / (2.0 * self.zoom);
        return .{
            .min_x = self.x - half_w,
            .min_y = self.y - half_h,
            .max_x = self.x + half_w,
            .max_y = self.y + half_h,
        };
    }

    /// Convert world coordinates to screen coordinates.
    pub fn worldToScreen(self: Camera, world_x: f32, world_y: f32) Vec2f {
        const sx = (world_x - self.x) * self.zoom + self.viewport_w / 2.0;
        const sy = (world_y - self.y) * self.zoom + self.viewport_h / 2.0;
        return .{ .x = sx, .y = sy };
    }

    /// Pan the camera by a delta (in pixels).
    pub fn pan(self: *Camera, dx: f32, dy: f32) void {
        self.x -= dx / self.zoom;
        self.y += dy / self.zoom;
        self.matrices_dirty = true;
    }

    /// Zoom in/out by a factor.
    pub fn zoomBy(self: *Camera, factor: f32) void {
        self.zoom = @max(0.25, @min(8.0, self.zoom * factor));
        self.matrices_dirty = true;
    }

    /// Center the camera on a position.
    pub fn centerOn(self: *Camera, world_x: f32, world_y: f32) void {
        self.x = world_x;
        self.y = world_y;
        self.matrices_dirty = true;
    }

    /// Wrap camera position so it stays within the map boundaries,
    /// creating a torus (infinite-scroll) effect. Call after panning.
    /// map_w and map_h are the map dimensions in pixels.
    pub fn wrap(self: *Camera, map_w: f32, map_h: f32) void {
        if (map_w <= 0 or map_h <= 0) return;
        // Wrap using modular arithmetic with fmod semantics
        self.x = @mod(self.x, map_w);
        self.y = @mod(self.y, map_h);
        // Ensure positive values (mod can return negative for negative inputs)
        if (self.x < 0) self.x += map_w;
        if (self.y < 0) self.y += map_h;
        self.matrices_dirty = true;
    }
};
