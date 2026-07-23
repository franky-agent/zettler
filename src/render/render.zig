//! Render module — re-exports all rendering types.

pub const Renderer = @import("Renderer.zig").Renderer;
pub const ClearColor = @import("Renderer.zig").ClearColor;
pub const gl = @import("gl.zig");
pub const glfw = @import("glfw.zig");
pub const Shader = @import("Shader.zig").Shader;
pub const Texture = @import("Texture.zig");
pub const Camera = @import("Camera.zig").Camera;
pub const map_renderer = @import("map_renderer.zig");
pub const sprite_batcher = @import("sprite_batcher.zig");
pub const texture_atlas = @import("texture_atlas.zig");
pub const culling = @import("culling.zig");

pub const MapRenderer = map_renderer.MapRenderer;
pub const SpriteBatcher = sprite_batcher.SpriteBatcher;
pub const TextureAtlas = texture_atlas.TextureAtlas;
pub const AtlasEntry = texture_atlas.AtlasEntry;
pub const App = @import("app.zig").App;
