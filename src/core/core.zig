//! Core module — re-exports all core types and enums.

pub const enums = @import("enums.zig");
pub const types = @import("types.zig");
pub const map = @import("Map.zig");
pub const game_state = @import("GameState.zig");
pub const player_state = @import("PlayerState.zig");
pub const building_state = @import("BuildingState.zig");
pub const flag_state = @import("FlagState.zig");
pub const serf_state = @import("SerfState.zig");
pub const random = @import("Random.zig");
pub const inventory = @import("Inventory.zig");
pub const pathfinder = @import("Pathfinder.zig");
pub const serf = @import("Serf.zig");
pub const building = @import("Building.zig");
pub const player = @import("Player.zig");
pub const flag = @import("Flag.zig");
pub const game = @import("Game.zig");
pub const noise = @import("Noise.zig");

pub const Direction = enums.Direction;
pub const Resource = enums.Resource;
pub const Building = enums.Building;
pub const SerfType = enums.SerfType;
pub const SerfStateEnum = enums.SerfState;

pub const MapPos = types.MapPos;
pub const GameObjectIndex = types.GameObjectIndex;
pub const PlayerIndex = types.PlayerIndex;
pub const Vec2i = types.Vec2i;
pub const Vec2f = types.Vec2f;
pub const Mat4 = types.Mat4;
pub const Rect = types.Rect;
