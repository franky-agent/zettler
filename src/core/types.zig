//! Core types for Freeserf
//!
//! Shared types used across the game engine.

const std = @import("std");
const enums = @import("enums.zig");

/// A position on the game map, stored as a packed u32.
/// The map uses the original Settlers (freeserf C++) sheared-grid model:
/// a regular square grid of (col, row) where each tile is a rhombus
/// rendered as a diamond in isometric projection.
/// MapPos encodes col and row into a single integer: (row * width + col).
pub const MapPos = packed struct(u32) {
    x: u16,
    y: u16,

    pub const zero: MapPos = .{ .x = 0, .y = 0 };
    pub const invalid: MapPos = .{ .x = 0xFFFF, .y = 0xFFFF };

    pub fn eql(self: MapPos, other: MapPos) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }

    /// Convert position to a linear index in the map array.
    pub fn toIndex(self: MapPos, width: u16) u32 {
        return @as(u32, self.y) * width + @as(u32, self.x);
    }

    /// Create from a linear index.
    pub fn fromIndex(index: u32, width: u16) MapPos {
        return .{
            .x = @intCast(index % width),
            .y = @intCast(index / width),
        };
    }

    /// Move one step in the given direction.
    /// Uses the C++ freeserf sheared-grid model (map-geometry.h):
    ///   Right(0):   col+1
    ///   DownRight(1): col+1, row+1
    ///   Down(2):     row+1
    ///   Left(3):    col-1
    ///   UpLeft(4):  col-1, row-1
    ///   Up(5):      row-1
    /// The rendering projection (screen_x = col*32 - row*16, screen_y = row*20)
    /// turns this into a hex-like diamond layout. There is NO row-parity
    /// offset logic — the shear is purely in the rendering projection.
    pub fn move(self: MapPos, dir: enums.Direction) MapPos {
        var x = self.x;
        var y = self.y;
        switch (dir) {
            .right     => x +%= 1,
            .down_right => {
                x +%= 1;
                y +%= 1;
            },
            .down      => y +%= 1,
            .left      => x -%= 1,
            .up_left   => {
                x -%= 1;
                y -%= 1;
            },
            .up        => y -%= 1,
        }
        return .{ .x = x, .y = y };
    }
};

/// Game object index type — used to reference serfs, buildings, flags, etc.
pub const GameObjectIndex = packed struct(u32) {
    index: u32,

    pub const invalid: GameObjectIndex = .{ .index = 0xFFFFFFFF };
    pub const max: u32 = 0x00FFFFFF;

    pub fn isValid(self: GameObjectIndex) bool {
        return self.index != invalid.index;
    }
};

/// Player index (0-5, 6 players max).
pub const PlayerIndex = packed struct(u8) {
    index: u8,

    pub const invalid: PlayerIndex = .{ .index = 0xFF };
    pub const max_players: u8 = 6;

    pub fn isValid(self: PlayerIndex) bool {
        return self.index < max_players;
    }
};

/// A 2D integer vector (used for screen coordinates, tile offsets).
pub const Vec2i = struct {
    x: i32,
    y: i32,

    pub const zero: Vec2i = .{ .x = 0, .y = 0 };

    pub fn add(self: Vec2i, other: Vec2i) Vec2i {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2i, other: Vec2i) Vec2i {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
};

/// A 2D float vector (used for rendering positions).
pub const Vec2f = struct {
    x: f32,
    y: f32,

    pub const zero: Vec2f = .{ .x = 0, .y = 0 };

    pub fn add(self: Vec2f, other: Vec2f) Vec2f {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2f, other: Vec2f) Vec2f {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2f, s: f32) Vec2f {
        return .{ .x = self.x * s, .y = self.y * s };
    }
};

/// A 4×4 matrix for orthographic projection (column-major).
pub const Mat4 = struct {
    data: [16]f32 = [_]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },

    /// Create an orthographic projection matrix.
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var m = Mat4{};
        m.data[0] = 2.0 / (right - left);
        m.data[5] = 2.0 / (top - bottom);
        m.data[10] = -2.0 / (far - near);
        m.data[12] = -(right + left) / (right - left);
        m.data[13] = -(top + bottom) / (top - bottom);
        m.data[14] = -(far + near) / (far - near);
        return m;
    }

    /// Multiply two 4×4 matrices.
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var result: Mat4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += self.data[row * 4 + k] * other.data[k * 4 + col];
                }
                result.data[row * 4 + col] = sum;
            }
        }
        return result;
    }
};

/// A rectangle in 2D space (used for UI layout, sprite clipping).
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }
};

test "MapPos movement" {
    const pos = MapPos{ .x = 10, .y = 10 };
    const moved = pos.move(enums.Direction.right);
    try std.testing.expectEqual(@as(u16, 11), moved.x);
    try std.testing.expectEqual(@as(u16, 10), moved.y);
}

test "Mat4 ortho" {
    const m = Mat4.ortho(0, 800, 600, 0, -1, 1);
    try std.testing.expectApproxEqAbs(2.0 / 800.0, m.data[0], 0.001);
    try std.testing.expectApproxEqAbs(2.0 / 600.0, m.data[5], 0.001);
}

test "Direction opposite" {
    try std.testing.expectEqual(enums.Direction.left, enums.Direction.right.opposite());
    try std.testing.expectEqual(enums.Direction.right, enums.Direction.left.opposite());
    try std.testing.expectEqual(enums.Direction.down_right, enums.Direction.up_left.opposite());
}

test "GameObjectIndex invalid" {
    const idx = GameObjectIndex.invalid;
    try std.testing.expect(!idx.isValid());
}

test "Resource names" {
    try std.testing.expectEqualStrings("Fish", @tagName(enums.Resource.fish));
}
