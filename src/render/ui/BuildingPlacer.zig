//! BuildingPlacer — handles mouse-based building placement on the map.
//!
//! When a building type is selected from the menu, this tool:
//! - Shows a ghost preview at the cursor position
//! - Validates terrain suitability
//! - Places the building on left-click
//! - Cancels on right-click

const std = @import("std");
const core = @import("core");
const gl = @import("../gl.zig");
const Shader = @import("../Shader.zig").Shader;
const Camera = @import("../Camera.zig").Camera;
const SpriteBatcher = @import("../sprite_batcher.zig").SpriteBatcher;
const Event = @import("Event.zig");
const Rect = Event.Rect;

const Game = core.game.Game;
const Map = core.map.Map;
const Building = core.Building;
const MapPos = core.types.MapPos;

/// Tile size constants (match map_renderer.zig).
pub const TileWidth: f32 = 32.0;
pub const TileHeight: f32 = 20.0;
pub const HalfTileWidth: f32 = TileWidth / 2.0;

/// Building placement tool.
pub const BuildingPlacer = struct {
    /// The building type currently being placed.
    building_type: Building = .none,
    /// Whether placement mode is active.
    active: bool = false,
    /// Ghost preview position (world coords of tile center).
    ghost_x: f32 = 0,
    ghost_y: f32 = 0,
    /// Map position of the ghost.
    ghost_pos: MapPos = .{ .x = 0, .y = 0 },
    /// Whether the current ghost position is valid for placement.
    can_place: bool = false,
    /// Colour of the ghost overlay.
    ghost_color: [4]f32 = .{ 0.0, 1.0, 0.0, 0.3 },

    pub fn init() BuildingPlacer {
        return BuildingPlacer{};
    }

    /// Activate placement mode for a building type.
    pub fn activate(self: *BuildingPlacer, btype: Building) void {
        self.building_type = btype;
        self.active = true;
    }

    /// Deactivate placement mode.
    pub fn deactivate(self: *BuildingPlacer) void {
        self.building_type = .none;
        self.active = false;
    }

    /// Update the ghost position based on mouse screen coordinates.
    /// `camera` is used for screen-to-world conversion.
    pub fn updateGhost(self: *BuildingPlacer, mouse_x: f32, mouse_y: f32, camera: *Camera, map: *Map) void {
        if (!self.active) return;

        // Convert screen to world
        const world = camera.screenToWorld(mouse_x, mouse_y);

        // Convert world to map tile (inverse of map_renderer projection):
        // screen_x = col * TileWidth - row * HalfTileWidth
        // screen_y = row * TileHeight
        // Solving for row, col:
        // row = screen_y / TileHeight
        // col = (screen_x + row * HalfTileWidth) / TileWidth
        const row_f = world.y / TileHeight;
        const col_f = (world.x + row_f * HalfTileWidth) / TileWidth;
        const col: i32 = @intFromFloat(@round(col_f));
        const row: i32 = @intFromFloat(@round(row_f));

        self.ghost_pos = .{ .x = map.wrapX(col), .y = map.wrapY(row) };

        // Validate terrain — must match Game.placeBuilding exactly so the
        // green/red ghost reflects what will actually be allowed. Mines go on
        // rocky high ground (snow/mountain); other buildings on buildable land;
        // nothing on water.
        self.can_place = false;
        if (map.isValidPos(self.ghost_pos)) {
            const tile = map.getTile(self.ghost_pos);
            if (!tile.has_building) {
                self.can_place = if (self.building_type.isMine())
                    tile.terrain.isMineable()
                else
                    tile.terrain.isBuildable();
            }
        }

        // Ghost world position (tile center in world coords)
        self.ghost_x = @as(f32, @floatFromInt(col)) * TileWidth - @as(f32, @floatFromInt(row)) * HalfTileWidth;
        self.ghost_y = @as(f32, @floatFromInt(row)) * TileHeight;

        self.ghost_color = if (self.can_place) .{ 0.0, 1.0, 0.0, 0.3 } else .{ 1.0, 0.0, 0.0, 0.3 };
    }

    /// Try to place a building at the ghost position.
    /// Returns the building index if placed, null otherwise.
    pub fn tryPlace(self: *BuildingPlacer, game: *Game, player: u8) !?core.types.GameObjectIndex {
        if (!self.active or !self.can_place) return null;
        if (self.building_type == .none) return null;

        const result = try game.placeBuilding(self.ghost_pos, self.building_type, player);
        if (result != null) {
            // Success — building placed, stay in placement mode for multi-place
        }
        return result;
    }

    /// Draw the ghost preview.
    pub fn drawGhost(self: *BuildingPlacer, batcher: *SpriteBatcher) void {
        if (!self.active) return;

        // Draw a semi-transparent overlay at the ghost position
        batcher.add(.{
            .x = self.ghost_x - HalfTileWidth,
            .y = self.ghost_y - TileHeight,
            .width = TileWidth,
            .height = TileHeight * 2,
            .u = 0, .v = 0, .uw = 0, .vh = 0,
            .r = self.ghost_color[0],
            .g = self.ghost_color[1],
            .b = self.ghost_color[2],
            .a = self.ghost_color[3],
        });
    }
};