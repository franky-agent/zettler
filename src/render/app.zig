//! App — GLFW game window with real sprite rendering from game data.
//!
//! Loads SPAE.PA game data, builds a texture atlas, renders the map
//! with real terrain sprites, shows buildings, and handles input.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const gl = @import("gl.zig");
const glfw = @import("glfw.zig");
const shader_mod = @import("Shader.zig");
const camera_mod = @import("Camera.zig");
const map_renderer_mod = @import("map_renderer.zig");
const sprite_batcher_mod = @import("sprite_batcher.zig");
const texture_atlas_mod = @import("texture_atlas.zig");
const font_mod = @import("Font.zig");
const panel_mod = @import("ui/Panel.zig");
const minimap_mod = @import("ui/Minimap.zig");
const building_placer_mod = @import("ui/BuildingPlacer.zig");
const road_builder_mod = @import("ui/RoadBuilder.zig");
const event_mod = @import("ui/Event.zig");

const Game = core.game.Game;
const Camera = camera_mod.Camera;
const Shader = shader_mod.Shader;
const MapRenderer = map_renderer_mod.MapRenderer;
const SpriteBatcher = sprite_batcher_mod.SpriteBatcher;
const TextureAtlas = texture_atlas_mod.TextureAtlas;
const Texture = @import("Texture.zig").Texture;
const PakFile = data.PakFile;
const BmpDecoder = data.BmpDecoder;
const sprite_ids = data.sprite_ids;
const Resource = core.Resource;
const Building = core.Building;
const Font = font_mod.Font;
const Panel = panel_mod.Panel;
const Minimap = minimap_mod.Minimap;
const BuildingPlacer = building_placer_mod.BuildingPlacer;
const RoadBuilder = road_builder_mod.RoadBuilder;
const MouseButton = event_mod.MouseButton;
const ToolMode = event_mod.ToolMode;

pub const WINDOW_WIDTH: c_int = 1024;
pub const WINDOW_HEIGHT: c_int = 768;
pub const WINDOW_TITLE: [:0]const u8 = "Freeserf Zig";

/// A 1x1 white fallback texture for when the real atlas isn't loaded.
/// The shader multiplies colors by texture2D, so we need a white texture
/// for colored quads to appear (otherwise texture2D returns black).
var fallback_tex: gl.GLuint = 0;

pub fn initFallbackTexture() void {
    if (fallback_tex != 0) return;
    fallback_tex = gl.genTextures(1);
    gl.bindTexture(gl.GL_TEXTURE_2D, fallback_tex);
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    gl.texImage2D(gl.GL_TEXTURE_2D, 0, @intCast(gl.GL_RGBA8), 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &white_pixel);
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
}

const MapObject = core.map.MapObject;

/// AssetMapObject sprite ids for harvestable map objects: trees (offsets 0-15:
/// deciduous 0-7, pine 8-15) and rocks (offsets 64-71).
fn mapObjectSpriteIds() [24]u16 {
    var ids: [24]u16 = undefined;
    var k: usize = 0;
    var off: u16 = 0;
    while (off < 16) : (off += 1) {
        ids[k] = sprite_ids.MAP_OBJECT_BASE + off;
        k += 1;
    }
    off = 64;
    while (off < 72) : (off += 1) {
        ids[k] = sprite_ids.MAP_OBJECT_BASE + off;
        k += 1;
    }
    return ids;
}

/// Shadow sprite ids (AssetMapShadow, +250) for the map objects above.
fn mapObjectShadowIds() [24]u16 {
    var ids = mapObjectSpriteIds();
    for (&ids) |*v| v.* += 250;
    return ids;
}

/// Queue a thick line segment (as a rotated quad) into the batcher. Used for
/// drawing roads. Bind the white fallback texture before flushing.
fn addLine(batcher: *SpriteBatcher, x0: f32, y0: f32, x1: f32, y1: f32, thick: f32, c: [4]f32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const nx = -dy / len * (thick * 0.5);
    const ny = dx / len * (thick * 0.5);
    batcher.addRawQuad(
        x0 + nx, y0 + ny,
        x1 + nx, y1 + ny,
        x1 - nx, y1 - ny,
        x0 - nx, y0 - ny,
        c[0], c[1], c[2], c[3],
    );
}

/// PAK sprite id for a standing object of the given family + variant (0..7).
fn objectSpriteId(obj: MapObject, variant: u8) u16 {
    const v: u16 = @min(variant, 7);
    const off: u16 = switch (obj) {
        .tree => v,
        .pine => 8 + v,
        .stone => 64 + v,
        .none => 0,
    };
    return sprite_ids.MAP_OBJECT_BASE + off;
}

/// Queue an atlas sprite into the batcher at world position (wx,wy) + the
/// sprite's hotspot offset. `reveal` (0..1) keeps only the bottom fraction of
/// the sprite visible (clipping the top in both geometry and UV) so a building
/// appears to grow upward from the ground during construction; reveal=1 draws
/// the whole sprite. `alpha` tints the sprite's opacity.
fn addSprite(batcher: *SpriteBatcher, e: texture_atlas_mod.AtlasEntry, wx: f32, wy: f32, reveal: f32, alpha: f32) void {
    const ph: f32 = @floatFromInt(e.pixel_h);
    const hidden = ph * (1.0 - reveal); // top pixels clipped away
    batcher.add(.{
        .x = wx + @as(f32, @floatFromInt(e.off_x)),
        .y = wy + @as(f32, @floatFromInt(e.off_y)) + hidden,
        .width = @floatFromInt(e.pixel_w),
        .height = ph * reveal,
        .u = e.u,
        .v = e.v + e.vh * (1.0 - reveal),
        .uw = e.uw,
        .vh = e.vh * reveal,
        .r = 1, .g = 1, .b = 1, .a = alpha,
    });
}

pub const App = struct {
    allocator: std.mem.Allocator,
    window: *glfw.GLFWwindow,
    game: Game,
    camera: Camera,
    map_renderer: MapRenderer,
    sprite_batcher: SpriteBatcher,
    shader: Shader,
    atlas: TextureAtlas = undefined,
    atlas_loaded: bool = false,
    pak: ?PakFile = null,
    decoder: BmpDecoder = undefined,
    running: bool = true,
    frame_count: u64 = 0,
    fps: f32 = 0,
    frame_times: [60]f64 = @splat(0),
    ft_index: usize = 0,
    initialized: bool = false,
    scroll_left: bool = false,
    scroll_right: bool = false,
    scroll_up: bool = false,
    scroll_down: bool = false,
    scroll_speed: f32 = 300.0,
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_down: bool = false,
    mouse_drag_start_x: f64 = 0,
    mouse_drag_start_y: f64 = 0,
    cam_drag_start_x: f32 = 0,
    cam_drag_start_y: f32 = 0,
    font: Font,
    font_loaded: bool = false,
    panel: Panel,
    minimap: Minimap,
    building_placer: BuildingPlacer,
    road_builder: RoadBuilder = .{},
    show_hud: bool = true,
    /// Live window size (window/screen coordinates — the same space GLFW reports
    /// the cursor in). UI projection + panel/minimap layout track this so the
    /// HUD stays aligned with the mouse after the window is resized. Hardcoding
    /// WINDOW_WIDTH/HEIGHT here would stretch the UI on resize and make menu
    /// clicks land on the wrong icon.
    view_w: f32 = @floatFromInt(WINDOW_WIDTH),
    view_h: f32 = @floatFromInt(WINDOW_HEIGHT),

    pub fn init(allocator: std.mem.Allocator) !App {
        var game_state = try Game.init(allocator, 64, 64, 1);
        errdefer game_state.deinit();

        var camera = Camera{};
        camera.setViewportSize(WINDOW_WIDTH, WINDOW_HEIGHT);
        camera.centerOn(32.0 * 32.0, 32.0 * 10.0); // map center: TileWidth=32
        camera.zoom = 2.0;

        return .{
            .allocator = allocator,
            .window = undefined,
            .game = game_state,
            .camera = camera,
            .map_renderer = .{},
            .sprite_batcher = SpriteBatcher.init(allocator),
            .shader = .{},
            .decoder = BmpDecoder.init(allocator),
            .font = try Font.init(allocator),
            .panel = Panel.init(),
            .minimap = Minimap.init(),
            .building_placer = BuildingPlacer.init(),
        };
    }

    pub fn deinit(self: *App) void {
        self.unloadPak();
        if (self.atlas_loaded) self.atlas.deinit();
        self.sprite_batcher.deinit();
        self.map_renderer.deinit();
        self.shader.deinit();
        self.game.deinit();
    }

    fn unloadPak(self: *App) void {
        if (self.pak) |*p| {
            p.deinit();
            self.pak = null;
        }
    }

    /// Load game data from SPAE.PA — read file using POSIX directly.
    pub fn loadGameData(self: *App, search_paths: []const []const u8) !bool {
        for (search_paths) |path| {
            std.debug.print("  Trying path: {s}\n", .{path});
            const raw = readFileToAlloc(self.allocator, path) catch |e| {
                std.debug.print("    error: {}\n", .{e});
                continue;
            };
            defer self.allocator.free(raw);

            var pak = PakFile.init(self.allocator, raw) catch |e| {
                std.debug.print("    PAK parse error: {}\n", .{e});
                continue;
            };
            self.pak = pak;
            std.debug.print("  Loaded {s}: {} files\n", .{ path, pak.fileCount() });

            // Load the companion palette file (same dir, "0.PAL")
            self.loadPalette(std.fs.path.dirname(path) orelse ".");
            return true;
        }
        return false;
    }

    fn loadPalette(self: *App, dir: []const u8) void {
        // The real game palette is stored inside SPAE.PA at entry #2
        // (freeserf's get_dos_palette(3) — index-1 shift due to first dummy entry).
        // PAK entry #2 contains 768 bytes of 6-bit RGB palette data, no prefix.
        const pak = self.pak orelse {
            std.debug.print("  No PAK loaded, cannot load palette\n", .{});
            return;
        };

        // PAK entry 2 is always the palette (768 bytes, straight 6-bit RGB)
        const pal_data = pak.getFile(2) catch |e| {
            std.debug.print("  Could not read PAK palette entry: {}\n", .{e});
            // Fallback: try external 0.PAL
            self.loadExternalPal(dir);
            return;
        };

        if (pal_data.len < 768) {
            std.debug.print("  PAK palette too short: {d} bytes\n", .{pal_data.len});
            return;
        }

        // PAK palette stores 256 entries of 8-bit RGB (r, g, b).
        // Our OpenGL uses GL_RGBA which expects {R, G, B, A} — same order.
        var palette: [256]data.bmp.ColorRGBA = undefined;
        for (0..256) |i| {
            palette[i] = data.bmp.ColorRGBA{
                .r = if (i == 0) 0 else pal_data[i * 3],
                .g = if (i == 0) 0 else pal_data[i * 3 + 1],
                .b = if (i == 0) 0 else pal_data[i * 3 + 2],
                .a = if (i == 0) 0 else 255,
            };
        }

        self.decoder.setPalette(palette);
        std.debug.print("  Palette loaded from PAK entry #2: 768 bytes, 256 colors\n", .{});
    }

    /// Fallback: load palette from external 0.PAL file.
    /// The external PAL files have a 4-byte prefix then 768 bytes of palette data.
    fn loadExternalPal(self: *App, dir: []const u8) void {
        const pal_path = std.fmt.allocPrint(self.allocator, "{s}/0.PAL", .{dir}) catch return;
        defer self.allocator.free(pal_path);

        const raw = readFileToAlloc(self.allocator, pal_path) catch {
            std.debug.print("  External 0.PAL not found, using grayscale\n", .{});
            return;
        };
        defer self.allocator.free(raw);

        const decompressed = data.Tpwm.decompress(self.allocator, raw) catch {
            if (data.bmp.parsePalette(raw)) |pal| {
                self.decoder.setPalette(pal);
                std.debug.print("  External palette loaded (raw)\n", .{});
            }
            return;
        };
        defer self.allocator.free(decompressed);

        // PAL files have 4-byte prefix, skip it
        if (data.bmp.parsePalette(decompressed)) |pal| {
            self.decoder.setPalette(pal);
            std.debug.print("  External palette loaded (TPWM, {d} bytes)\n", .{decompressed.len});
        } else if (decompressed.len >= 4 + 768) {
            // Parse with 4-byte offset manually
            var pal_manual: [256]data.bmp.ColorRGBA = undefined;
            for (0..256) |i| {
                const off = 4 + i * 3;
                pal_manual[i] = data.bmp.ColorRGBA{
                    .r = @intCast(@min(@as(u32, decompressed[off]) * 4, 255)),
                    .g = @intCast(@min(@as(u32, decompressed[off + 1]) * 4, 255)),
                    .b = @intCast(@min(@as(u32, decompressed[off + 2]) * 4, 255)),
                    .a = if (i == 0) 0 else 255,
                };
            }
            self.decoder.setPalette(pal_manual);
            std.debug.print("  External palette loaded (manual offset=4)\n", .{});
        }
    }

    /// Build the texture atlas from PAK contents.
    pub fn buildAtlas(self: *App) !void {
        const pak = self.pak orelse return;
        var atlas = try TextureAtlas.init(self.allocator);
        errdefer atlas.deinit();

        // Terrain sprites: PAK 260-292 (C++ AssetMapGround, base 260, offsets 0-32).
        // Offset 32 (PAK 292) is the water sprite used for all Water terrain types.
        try atlas.loadRange(&pak, &self.decoder, 260, 293);

        // Animated water waves: AssetMapWaves PAK 630-645 (16 frames, 48×19,
        // transparent sprites). Drawn as an overlay on water tiles.
        try atlas.loadRange(&pak, &self.decoder, 630, 646);

        // Building sprites: specific PAK indices from AssetMapObject
        // (base 1250 + hex offsets from C++ map_building_sprite[])
        const building_ids = [_]u16{
            sprite_ids.MAP_OBJECT_BASE + 0x98,  // fortress
            sprite_ids.MAP_OBJECT_BASE + 0x99,  // toolmaker
            sprite_ids.MAP_OBJECT_BASE + 0x9a,  // farm
            sprite_ids.MAP_OBJECT_BASE + 0x9b,  // pig_farm
            sprite_ids.MAP_OBJECT_BASE + 0x9c,  // slaughterhouse
            sprite_ids.MAP_OBJECT_BASE + 0x9d,  // armory
            sprite_ids.MAP_OBJECT_BASE + 0x9e,  // tower
            sprite_ids.MAP_OBJECT_BASE + 0x9f,  // gold_smelter
            sprite_ids.MAP_OBJECT_BASE + 0xa0,  // sawmill
            sprite_ids.MAP_OBJECT_BASE + 0xa1,  // iron_smelter
            sprite_ids.MAP_OBJECT_BASE + 0xa2,  // bakery
            sprite_ids.MAP_OBJECT_BASE + 0xa3,  // granite_mine
            sprite_ids.MAP_OBJECT_BASE + 0xa4,  // coal_mine
            sprite_ids.MAP_OBJECT_BASE + 0xa5,  // iron_mine
            sprite_ids.MAP_OBJECT_BASE + 0xa6,  // gold_mine
            sprite_ids.MAP_OBJECT_BASE + 0xa7,  // fisher
            sprite_ids.MAP_OBJECT_BASE + 0xa8,  // lumberjack
            sprite_ids.MAP_OBJECT_BASE + 0xa9,  // stonecutter
            sprite_ids.MAP_OBJECT_BASE + 0xaa,  // forester
            sprite_ids.MAP_OBJECT_BASE + 0xae,  // boatbuilder
            sprite_ids.MAP_OBJECT_BASE + 0xb2,  // castle
            sprite_ids.MAP_OBJECT_BASE + 0xbc,  // mill
            sprite_ids.MAP_OBJECT_BASE + 0xc0,  // stock
        };
        try atlas.loadBuildingSprites(&pak, &self.decoder, &building_ids);

        // Building shadows: AssetMapShadow (PAK base 1500) shares the same per-
        // building offsets as AssetMapObject (PAK base 1250), so each shadow id is
        // the building sprite id + 250. Decoded as semi-transparent overlays.
        var shadow_ids: [building_ids.len]u16 = undefined;
        for (building_ids, 0..) |bid, idx| shadow_ids[idx] = bid + 250;
        try atlas.loadOverlaySprites(&pak, &self.decoder, &shadow_ids);

        // Construction: the foundation "plan" cross (sprite 0x90) shown at
        // progress 0, plus its shadow. The building's own sprite (loaded above)
        // is what rises out of the ground for the rest of construction.
        const plan_ids = [_]u16{sprite_ids.Building.PLAN};
        try atlas.loadBuildingSprites(&pak, &self.decoder, &plan_ids);
        const plan_shadow_ids = [_]u16{sprite_ids.Building.PLAN + 250};
        try atlas.loadOverlaySprites(&pak, &self.decoder, &plan_shadow_ids);

        // Map objects: trees (AssetMapObject 0-15: deciduous 0-7, pine 8-15) and
        // rocks (64-71), plus their shadows (+250). These are what gatherers
        // harvest. (C++ viewport.cc: object sprite = obj - ObjectTree0.)
        try atlas.loadBuildingSprites(&pak, &self.decoder, &mapObjectSpriteIds());
        try atlas.loadOverlaySprites(&pak, &self.decoder, &mapObjectShadowIds());

        atlas.upload() catch |e| {
            std.debug.print("  Atlas upload error: {}\n", .{e});
            return;
        };

        self.atlas = atlas;
        self.atlas_loaded = true;
        std.debug.print("  Atlas: {} sprites packed, {}x{} texture\n", .{
            atlas.count(), texture_atlas_mod.ATLAS_SIZE, texture_atlas_mod.ATLAS_SIZE,
        });

        // Rebuild map VBO with atlas UV coordinates
        if (self.initialized) {
            self.map_renderer.rebuildWithAtlas(&self.game.state.map, &self.atlas) catch |e| {
                std.debug.print("  rebuildWithAtlas error: {}\n", .{e});
            };
        }
    }

    pub fn createWindow(self: *App) !void {
        current_app = self;

        if (!glfw.init()) return error.GlfwInitFailed;
        errdefer glfw.terminate();

        // macOS provides OpenGL 2.1 by default via legacy profile
        // Do not set version hints on macOS - they can cause context creation failures
        glfw.windowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);

        const window = glfw.createWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE) orelse
            return error.WindowCreationFailed;
        self.window = window;
        glfw.makeContextCurrent(window);
        glfw.swapInterval(1); // V-Sync on

        glfw.setKeyCallback(window, onKey);
        glfw.setMouseButtonCallback(window, onMouseButton);
        glfw.setCursorPosCallback(window, onCursorPos);
        glfw.setScrollCallback(window, onScroll);
        glfw.setWindowSizeCallback(window, onWindowResize);

        gl.disable(gl.GL_DEPTH_TEST);
        gl.enable(gl.GL_BLEND);
        gl.blendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
        gl.clearColor(0.4, 0.6, 0.8, 1.0);

        // Sync to the actual window/framebuffer size (may differ from the
        // requested size, e.g. when the WM resizes or on HiDPI displays). The
        // viewport is in framebuffer pixels; UI/camera/mouse use window coords.
        const ws = glfw.getWindowSize(window);
        const fb = glfw.getFramebufferSize(window);
        gl.viewport(0, 0, fb.width, fb.height);
        self.setViewportSize(@floatFromInt(ws.width), @floatFromInt(ws.height));

        // Create fallback white texture for when no game data is loaded
        initFallbackTexture();

        self.shader = try Shader.createDefault();
        try self.sprite_batcher.initGL();
        try self.map_renderer.init(&self.game.state.map);

        self.initialized = true;
    }

    pub fn run(self: *App) !void {
        std.debug.print("  run: window={*} running={}\n", .{ self.window, self.running });
        std.debug.print("  shouldClose: {}\n", .{glfw.windowShouldClose(self.window)});
        std.debug.print("  atlas_loaded={} uploaded={}\n", .{ self.atlas_loaded, if (self.atlas_loaded) self.atlas.uploaded else false });
        std.debug.print("  map_renderer.initialized={}\n", .{self.map_renderer.initialized});
        std.debug.print("  sprite_batcher.gl_initialized={}\n", .{self.sprite_batcher.gl_initialized});
        std.debug.print("  shader.program={}\n", .{self.shader.program});

        var frames: u64 = 0;
        while (!glfw.windowShouldClose(self.window) and self.running) {
            glfw.pollEvents();
            self.handleInput();

            const const_tick: u64 = @intFromFloat(glfw.getTime() * 50.0);
            self.game.tick(const_tick);

            gl.clear(gl.GL_COLOR_BUFFER_BIT);

            // Render the hex map — NEAREST for pixel-exact fidelity to the
            // original DOS art (the original never blurs terrain).
            // The map renderer draws at 9 offsets for torus wrapping.
            if (self.atlas_loaded and self.atlas.uploaded) {
                self.atlas.setFilter(false); // nearest (binds atlas)
            } else {
                gl.bindTexture(gl.GL_TEXTURE_2D, fallback_tex);
            }
            self.shader.use();
            self.shader.setTexture(0);
            self.shader.setColor(1, 1, 1, 1);
            self.map_renderer.render(&self.camera);

            // Buildings & UI use NEAREST so pixel-art sprites stay crisp.
            if (self.atlas_loaded and self.atlas.uploaded) {
                self.atlas.setFilter(false); // nearest
            }
            // Render objects (waves, roads, scene) at each torus offset so they
            // wrap seamlessly along with the terrain.
            const mw = @as(f32, @floatFromInt(self.game.state.map.width)) * map_renderer_mod.TileWidth;
            const mh = @as(f32, @floatFromInt(self.game.state.map.height)) * map_renderer_mod.TileHeight;
            const offsets = [9][2]f32{
                .{ -mw, -mh }, .{ 0.0, -mh }, .{ mw, -mh },
                .{ -mw, 0.0 }, .{ 0.0, 0.0 }, .{ mw, 0.0 },
                .{ -mw, mh },  .{ 0.0, mh },  .{ mw, mh },
            };
            const saved_cx = self.camera.x;
            const saved_cy = self.camera.y;
            for (offsets) |off| {
                self.camera.x = saved_cx + off[0];
                self.camera.y = saved_cy + off[1];
                self.camera.matrices_dirty = true;
                self.renderWaves(const_tick);
                self.renderRoads();
                self.renderScene();
            }
            self.camera.x = saved_cx;
            self.camera.y = saved_cy;
            self.camera.matrices_dirty = true;

            // Render UI overlay (HUD + minimap + building ghost)
            if (self.show_hud and frames > 0) {
                self.renderUI(const_tick);
            }

            glfw.swapBuffers(self.window);
            self.frame_count += 1;
            frames += 1;

            if (frames == 1) std.debug.print("  frame 1 ok\n", .{});
        }
        std.debug.print("  run done: {} frames\n", .{frames});
    }

    /// Update the live window size used by the UI projection, camera and panel
    /// layout. Call whenever the window size changes (and once at startup).
    fn setViewportSize(self: *App, w: f32, h: f32) void {
        self.view_w = w;
        self.view_h = h;
        self.camera.setViewportSize(w, h);
        self.panel.setScreenSize(w, h);
    }

    fn handleInput(self: *App) void {
        const speed = self.scroll_speed / 60.0;
        if (self.scroll_left) self.camera.pan(-speed, 0);
        if (self.scroll_right) self.camera.pan(speed, 0);
        if (self.scroll_up) self.camera.pan(0, -speed);
        if (self.scroll_down) self.camera.pan(0, speed);
        // Wrap camera within map bounds for torus scrolling
        const mw = @as(f32, @floatFromInt(self.game.state.map.width)) * map_renderer_mod.TileWidth;
        const mh = @as(f32, @floatFromInt(self.game.state.map.height)) * map_renderer_mod.TileHeight;
        self.camera.wrap(mw, mh);
    }

    /// One drawable in the world scene: either a building (by index) or a
    /// standing map object on a tile (by x,y). `baseline` is the screen-space y
    /// used to sort back-to-front.
    const SceneItem = struct {
        baseline: f32,
        is_building: bool,
        bidx: u32 = 0,
        x: u16 = 0,
        y: u16 = 0,
    };

    /// Render the world scene: buildings and standing map objects (trees/rocks),
    /// interleaved and sorted back-to-front by screen baseline so nearer sprites
    /// and their shadows correctly occlude farther ones.
    fn renderScene(self: *App) void {
        const batcher = &self.sprite_batcher;
        const cam = &self.camera;
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const map = &self.game.state.map;
        const items = self.game.state.buildings.buildings.items;

        batcher.begin();

        const a = std.heap.page_allocator;
        const list = a.alloc(SceneItem, items.len + map.tileCount()) catch null;
        defer if (list) |l| a.free(l);

        if (list) |l| {
            var n: usize = 0;
            for (items, 0..) |*b, i| {
                const bh: f32 = @floatFromInt(map.getTile(b.pos).height);
                l[n] = .{
                    .baseline = @as(f32, @floatFromInt(b.pos.y)) * th - map_renderer_mod.HEIGHT_SCALE * bh,
                    .is_building = true,
                    .bidx = @intCast(i),
                };
                n += 1;
            }
            for (0..map.height) |yy| {
                for (0..map.width) |xx| {
                    const t = map.getTileXY(@intCast(xx), @intCast(yy));
                    if (t.object == .none) continue;
                    const oh: f32 = @floatFromInt(t.height);
                    l[n] = .{
                        .baseline = @as(f32, @floatFromInt(yy)) * th - map_renderer_mod.HEIGHT_SCALE * oh,
                        .is_building = false,
                        .x = @intCast(xx),
                        .y = @intCast(yy),
                    };
                    n += 1;
                }
            }
            std.mem.sort(SceneItem, l[0..n], {}, struct {
                fn lt(_: void, p: SceneItem, q: SceneItem) bool {
                    return p.baseline < q.baseline;
                }
            }.lt);
            for (l[0..n]) |e| {
                if (e.is_building) {
                    self.drawBuilding(batcher, &items[e.bidx], tw, th, hw);
                } else {
                    self.drawMapObject(batcher, e.x, e.y, tw, th, hw);
                }
            }
        } else {
            // Allocation failed: draw buildings unsorted (still correct).
            for (items) |*b| self.drawBuilding(batcher, b, tw, th, hw);
        }

        if (self.atlas_loaded and self.atlas.uploaded) {
            var atlas_tex = Texture{ .id = self.atlas.gl_texture, .width = texture_atlas_mod.ATLAS_SIZE, .height = texture_atlas_mod.ATLAS_SIZE };
            batcher.render(&self.shader, &atlas_tex, cam);
        } else {
            var white_tex = Texture{ .id = fallback_tex, .width = 1, .height = 1 };
            batcher.render(&self.shader, &white_tex, cam);
        }
    }

    /// Draw one standing map object (tree/rock) with its shadow.
    fn drawMapObject(self: *App, batcher: *SpriteBatcher, x: u16, y: u16, tw: f32, th: f32, hw: f32) void {
        const t = self.game.state.map.getTileXY(x, y);
        const oh: f32 = @floatFromInt(t.height);
        const wx = @as(f32, @floatFromInt(x)) * tw - @as(f32, @floatFromInt(y)) * hw;
        const wy = @as(f32, @floatFromInt(y)) * th - map_renderer_mod.HEIGHT_SCALE * oh;

        if (self.atlas_loaded and self.atlas.uploaded) {
            const sid = objectSpriteId(t.object, t.object_variant);
            if (self.atlas.has(sid)) {
                self.drawShadowedSprite(batcher, sid, wx, wy, 1.0);
                return;
            }
        }
        // Fallback: small coloured mark (green for trees, grey for rocks).
        const c: [3]f32 = if (t.object == .stone) .{ 0.55, 0.55, 0.55 } else .{ 0.12, 0.5, 0.12 };
        batcher.add(.{
            .x = wx - 4, .y = wy - 14, .width = 8, .height = 14,
            .u = 0, .v = 0, .uw = 0, .vh = 0,
            .r = c[0], .g = c[1], .b = c[2], .a = 1,
        });
    }

    /// World pixel center of a tile (top-anchored, with terrain height offset).
    fn tileCenter(self: *App, pos: core.MapPos) [2]f32 {
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const t = self.game.state.map.getTile(pos);
        const wx = @as(f32, @floatFromInt(pos.x)) * tw - @as(f32, @floatFromInt(pos.y)) * hw;
        const wy = @as(f32, @floatFromInt(pos.y)) * th -
            map_renderer_mod.HEIGHT_SCALE * @as(f32, @floatFromInt(t.height));
        return .{ wx, wy };
    }

    /// Convert the current mouse position to the map tile under the cursor.
    /// Uses wrapping so tiles across the map edge are correctly identified.
    fn mouseToTile(self: *App) core.MapPos {
        const world = self.camera.screenToWorld(@floatCast(self.mouse_x), @floatCast(self.mouse_y));
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const row_f = world.y / th;
        const col_f = (world.x + row_f * hw) / tw;
        const col: i32 = @intFromFloat(@round(col_f));
        const row: i32 = @intFromFloat(@round(row_f));
        const map = &self.game.state.map;
        return .{ .x = map.wrapX(col), .y = map.wrapY(row) };
    }

    /// Draw roads (segments between connected road/flag tiles), flag posts, and
    /// the road-building preview line. World-space, white fallback texture.
    fn renderRoads(self: *App) void {
        const batcher = &self.sprite_batcher;
        const map = &self.game.state.map;
        batcher.begin();

        // Road segments: for each road/flag tile, connect to forward neighbours
        // that are also road/flag (forward dirs only, to avoid drawing twice).
        // Uses WRAPPING so roads draw correctly across map edges.
        const fwd = [_]core.Direction{ .right, .down_right, .down };
        for (0..map.height) |yy| {
            for (0..map.width) |xx| {
                const pos = core.MapPos{ .x = @intCast(xx), .y = @intCast(yy) };
                const t = map.getTile(pos);
                if (!(t.has_road or t.has_flag)) continue;
                const c0 = self.tileCenter(pos);
                for (fwd) |d| {
                    const np = map.getNeighborWrapped(pos, d);
                    const nt = map.getTile(np);
                    if (!(nt.has_road or nt.has_flag)) continue;
                    const c1 = self.tileCenter(np);
                    addLine(batcher, c0[0], c0[1], c1[0], c1[1], 4.0, .{ 0.55, 0.4, 0.22, 1.0 });
                }
            }
        }

        // Flag posts.
        for (self.game.state.flags.flags.items) |*f| {
            const c = self.tileCenter(f.pos);
            batcher.add(.{ .x = c[0] - 1.5, .y = c[1] - 13, .width = 3, .height = 13, .u = 0, .v = 0, .uw = 0, .vh = 0, .r = 0.55, .g = 0.45, .b = 0.3, .a = 1 });
            batcher.add(.{ .x = c[0] - 1.5, .y = c[1] - 13, .width = 7, .height = 4, .u = 0, .v = 0, .uw = 0, .vh = 0, .r = 0.9, .g = 0.2, .b = 0.2, .a = 1 });
        }

        // Road-building preview: line from the chosen start flag to the cursor,
        // green if a path exists, red otherwise.
        if (self.road_builder.active and self.road_builder.has_start) {
            const c0 = self.tileCenter(self.road_builder.start_flag_pos);
            const c1 = self.tileCenter(self.road_builder.cursor_pos);
            const col: [4]f32 = if (self.road_builder.has_path)
                .{ 0.2, 0.9, 0.2, 0.8 }
            else
                .{ 0.9, 0.2, 0.2, 0.8 };
            addLine(batcher, c0[0], c0[1], c1[0], c1[1], 3.0, col);
        }

        if (batcher.sprite_count == 0) return;
        var white_tex = Texture{ .id = fallback_tex, .width = 1, .height = 1 };
        batcher.render(&self.shader, &white_tex, &self.camera);
    }

    /// Queue one building into the sprite batcher. Completed buildings draw their
    /// shadow + sprite; buildings under construction draw the animated build-up
    /// sequence (plan → scaffold frame → walls rising). Falls back to a colored
    /// rectangle when no sprite is available.
    fn drawBuilding(self: *App, batcher: *SpriteBatcher, b: anytype, tw: f32, th: f32, hw: f32) void {
        const bh: f32 = @floatFromInt(self.game.state.map.getTile(b.pos).height);
        const wx = @as(f32, @floatFromInt(b.pos.x)) * tw -
            @as(f32, @floatFromInt(b.pos.y)) * hw;
        const wy = @as(f32, @floatFromInt(b.pos.y)) * th -
            map_renderer_mod.HEIGHT_SCALE * bh;

        if (self.atlas_loaded and self.atlas.uploaded) {
            if (b.is_done) {
                if (sprite_ids.Building.fromGameBuilding(b.building_type)) |sid| {
                    self.drawShadowedSprite(batcher, sid, wx, wy, 1.0);
                    return;
                }
            } else if (self.drawConstruction(batcher, b, wx, wy)) {
                return;
            }
        }

        // Fallback: colored rectangle (no atlas, or no sprite for this type).
        const c = buildingColor(b.building_type);
        batcher.add(.{
            .x = wx - hw,
            .y = wy - th,
            .width = tw,
            .height = th * 2,
            .u = 0, .v = 0, .uw = 0, .vh = 0,
            .r = c[0], .g = c[1], .b = c[2], .a = if (b.is_done) 0.9 else 0.5,
        });
    }

    /// Draw a building's shadow (sprite id + 250) then the sprite itself, both at
    /// the building's hotspot offset. `reveal` (0..1) clips the sprite from the
    /// top so it appears to rise from the ground — matches the C++ construction
    /// effect (draw_sprite's `progress` → y_off in gfx.cc).
    fn drawShadowedSprite(self: *App, batcher: *SpriteBatcher, sprite_id: u16, wx: f32, wy: f32, reveal: f32) void {
        if (self.atlas.get(sprite_id + 250)) |sh| addSprite(batcher, sh, wx, wy, reveal, 1.0);
        if (self.atlas.get(sprite_id)) |e| addSprite(batcher, e, wx, wy, reveal, 1.0);
    }

    /// Draw an under-construction building. progress is 0..100 (see
    /// Game.updateBuildings).
    ///
    /// C++ freeserf (viewport.cc draw_building_unfinished) draws a wooden
    /// scaffold "frame" sprite (map_building_frame_sprite) + the building
    /// revealed bottom-up. We can't reproduce that here: small buildings share
    /// one generic lattice (0xba) that doesn't resemble them, and several frame
    /// sprites — including the stock's (0xc1) and the corner stone (0x91) — are
    /// EMPTY in this data file, so big buildings like the stock have no scaffold
    /// at all. Instead we keep every building recognisable as itself: show the
    /// foundation cross at progress 0, then the building's OWN full sprite
    /// fading in as it is built (translucent → solid). When done, drawBuilding
    /// draws it fully opaque.
    /// Returns false if no sprite is available for this type (colored fallback).
    fn drawConstruction(self: *App, batcher: *SpriteBatcher, b: anytype, wx: f32, wy: f32) bool {
        const Bld = sprite_ids.Building;

        if (b.progress == 0 and self.atlas.has(Bld.PLAN)) {
            self.drawShadowedSprite(batcher, Bld.PLAN, wx, wy, 1.0);
            return true;
        }

        const bld_id = Bld.fromGameBuilding(b.building_type) orelse return false;
        const t = @as(f32, @floatFromInt(b.progress)) / 100.0;

        // Full building, fading in (so a stock looks like a stock, a castle like
        // a castle, etc. — not a partial fragment). Shadow also fades in.
        if (self.atlas.get(bld_id + 250)) |sh| addSprite(batcher, sh, wx, wy, 1.0, 0.5 * t);
        if (self.atlas.get(bld_id)) |e| addSprite(batcher, e, wx, wy, 1.0, 0.4 + 0.5 * t);
        return true;
    }

    /// Draw animated water waves (AssetMapWaves) over every water tile. Frame is
    /// selected per-tile by the original formula ((pos ^ 5) + (tick >> 3)) & 0xf,
    /// giving 16 cycling frames (PAK 630-645).
    fn renderWaves(self: *App, tick: u64) void {
        if (!(self.atlas_loaded and self.atlas.uploaded)) return;
        const batcher = &self.sprite_batcher;
        const cam = &self.camera;
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const map = &self.game.state.map;

        // A wave sprite is 48×19 anchored at (wx-16, wy); its footprint covers the
        // tile plus its right / down / down-right neighbours. Only animate water
        // whose whole footprint is also water, otherwise the sprite "floods" the
        // adjacent grass. Shoreline water stays static (no spill).
        const isWater = struct {
            fn at(m: *core.map.Map, x: i32, y: i32) bool {
                return m.getTileWrapped(x, y).terrain == .water;
            }
        }.at;

        batcher.begin();
        var drew = false;
        for (0..map.height) |yy| {
            for (0..map.width) |xx| {
                const tile = map.getTileXY(@intCast(xx), @intCast(yy));
                if (tile.terrain != .water) continue;
                // Skip shoreline tiles to avoid waves spilling onto land.
                // Uses wrapping so edge water checks neighbours across the seam.
                const xxi: i32 = @intCast(xx);
                const yyi: i32 = @intCast(yy);
                if (!isWater(map, xxi + 1, yyi) or !isWater(map, xxi, yyi + 1) or
                    !isWater(map, xxi + 1, yyi + 1)) continue;
                const pos: u64 = @as(u64, yy) * map.width + xx;
                const frame: u16 = @intCast(((pos ^ 5) + (tick >> 3)) & 0xf);
                const entry = self.atlas.get(630 + frame) orelse continue;
                const wx = @as(f32, @floatFromInt(xx)) * tw - @as(f32, @floatFromInt(yy)) * hw;
                const wy = @as(f32, @floatFromInt(yy)) * th -
                    map_renderer_mod.HEIGHT_SCALE * @as(f32, @floatFromInt(tile.height));
                batcher.add(.{
                    .x = wx - hw,
                    .y = wy,
                    .width = @floatFromInt(entry.pixel_w),
                    .height = @floatFromInt(entry.pixel_h),
                    .u = entry.u, .v = entry.v, .uw = entry.uw, .vh = entry.vh,
                    .r = 1, .g = 1, .b = 1, .a = 1,
                });
                drew = true;
            }
        }
        if (!drew) return;
        var atlas_tex = Texture{ .id = self.atlas.gl_texture, .width = texture_atlas_mod.ATLAS_SIZE, .height = texture_atlas_mod.ATLAS_SIZE };
        batcher.render(&self.shader, &atlas_tex, cam);
    }

    /// Queue the building-placement ghost: the actual building sprite tinted
    /// green (valid spot) or red (invalid), semi-transparent, at the tile the
    /// building would occupy. Returns true if an atlas sprite was used (caller
    /// binds the atlas texture), false if it fell back to a flat coloured diamond
    /// (caller binds the white texture). The tint multiplies the sprite texture,
    /// so a green tint yields a recognisable green silhouette of the building.
    fn drawGhost(self: *App, batcher: *SpriteBatcher) bool {
        const placer = &self.building_placer;
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const tint = placer.ghost_color; // {r, g, b, a}

        // Place the ghost exactly where the finished building will sit (same
        // formula as drawBuilding, including terrain height).
        const bh: f32 = @floatFromInt(self.game.state.map.getTile(placer.ghost_pos).height);
        const wx = @as(f32, @floatFromInt(placer.ghost_pos.x)) * tw -
            @as(f32, @floatFromInt(placer.ghost_pos.y)) * hw;
        const wy = @as(f32, @floatFromInt(placer.ghost_pos.y)) * th -
            map_renderer_mod.HEIGHT_SCALE * bh;

        if (self.atlas_loaded and self.atlas.uploaded) {
            if (sprite_ids.Building.fromGameBuilding(placer.building_type)) |sid| {
                if (self.atlas.get(sid)) |e| {
                    batcher.add(.{
                        .x = wx + @as(f32, @floatFromInt(e.off_x)),
                        .y = wy + @as(f32, @floatFromInt(e.off_y)),
                        .width = @floatFromInt(e.pixel_w),
                        .height = @floatFromInt(e.pixel_h),
                        .u = e.u, .v = e.v, .uw = e.uw, .vh = e.vh,
                        .r = tint[0], .g = tint[1], .b = tint[2], .a = 0.55,
                    });
                    return true;
                }
            }
        }

        // Fallback: flat coloured diamond.
        batcher.add(.{
            .x = wx - hw, .y = wy - th,
            .width = tw, .height = th * 2,
            .u = 0, .v = 0, .uw = 0, .vh = 0,
            .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3],
        });
        return false;
    }

    /// Draw the build-menu icons: each building's actual sprite, scaled to fit
    /// its menu cell and centred. Emitted into the current batch; the caller
    /// flushes with the atlas texture bound (screen-space / orthographic).
    fn drawMenuIcons(self: *App, batcher: *SpriteBatcher) void {
        const icon: f32 = panel_mod.ICON_SIZE;
        for (panel_mod.BUILD_MENU, 0..) |b, i| {
            const region = self.panel.menu_regions[i];
            const sid = sprite_ids.Building.fromGameBuilding(b) orelse continue;
            const e = self.atlas.get(sid) orelse continue;
            const pw: f32 = @floatFromInt(e.pixel_w);
            const ph: f32 = @floatFromInt(e.pixel_h);
            if (pw == 0 or ph == 0) continue;
            // Scale to fit the cell (leave a 2px inset), preserving aspect.
            const scale = @min((icon - 4) / pw, (icon - 4) / ph);
            const dw = pw * scale;
            const dh = ph * scale;
            batcher.add(.{
                .x = region.rect.x + (icon - dw) / 2.0,
                .y = region.rect.y + (icon - dh) / 2.0,
                .width = dw, .height = dh,
                .u = e.u, .v = e.v, .uw = e.uw, .vh = e.vh,
                .r = 1, .g = 1, .b = 1, .a = 1,
            });
        }
    }

    fn buildingColor(b: Building) [3]f32 {
        return switch (b) {
            .lumberjack => .{ 0.50, 0.80, 0.30 },
            .stonecutter => .{ 0.65, 0.65, 0.65 },
            .fisher => .{ 0.25, 0.50, 0.90 },
            .forester => .{ 0.15, 0.85, 0.20 },
            .sawmill => .{ 0.70, 0.45, 0.15 },
            .farm => .{ 0.90, 0.80, 0.20 },
            .mill => .{ 0.80, 0.70, 0.35 },
            .tower => .{ 0.75, 0.20, 0.20 },
            .stock => .{ 0.85, 0.60, 0.10 },
            else => .{ 0.70, 0.70, 0.70 },
        };
    }

    fn flushUI(self: *App, ortho: *const [16]f32) void {
        self.flushUITex(ortho, fallback_tex);
    }

    /// Flush the current screen-space (orthographic) UI batch with a specific
    /// texture bound. Used for white-quad/text UI (fallback_tex) and for the
    /// build-menu building-sprite icons (the atlas texture).
    fn flushUITex(self: *App, ortho: *const [16]f32, tex: gl.GLuint) void {
        const batcher = &self.sprite_batcher;
        if (batcher.sprite_count == 0) return;

        gl.bindTexture(gl.GL_TEXTURE_2D, tex);
        self.shader.use();
        self.shader.setTexture(0);
        self.shader.setColor(1, 1, 1, 1);
        self.shader.setOffset(0, 0);
        self.shader.setProjection(ortho);
        const mv: [16]f32 = (core.Mat4{}).data;
        self.shader.setModelview(&mv);

        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, batcher.ibo);
        gl.bindBuffer(gl.GL_ARRAY_BUFFER, batcher.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(batcher.vertices[0 .. batcher.sprite_count * 4]), gl.GL_DYNAMIC_DRAW);

        const stride: i32 = @sizeOf(sprite_batcher_mod.SpriteVertex);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 8);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 16);
        gl.drawElements(gl.GL_TRIANGLES, @intCast(batcher.sprite_count * 6), gl.GL_UNSIGNED_SHORT, 0);
        gl.disableVertexAttribArray(0);
        gl.disableVertexAttribArray(1);
        gl.disableVertexAttribArray(2);

        batcher.sprite_count = 0;
    }

    fn renderUI(self: *App, tick: u64) void {
        _ = tick;
        const batcher = &self.sprite_batcher;

        // Build orthographic projection for screen-space UI, using the live
        // window size so the UI maps 1:1 to cursor coordinates after a resize.
        var ortho: [16]f32 = undefined;
        {
            var m: core.Mat4 = .{};
            m.data[0] = 2.0 / self.view_w;
            m.data[5] = -2.0 / self.view_h;
            m.data[12] = -1.0;
            m.data[13] = 1.0;
            ortho = m.data;
        }

        // Ensure font texture is loaded
        if (!self.font_loaded) {
            self.font.uploadFallback();
            self.font_loaded = true;
        }

        // Update minimap position
        self.minimap.setPosition(self.view_w, self.view_h);

        // Feed the cursor position to the panel so hover highlights/tooltips work.
        self.panel.mouse_x = @floatCast(self.mouse_x);
        self.panel.mouse_y = @floatCast(self.mouse_y);

        // ── Panel HUD (top bar + building menu + resource counts) ──
        batcher.begin();
        self.panel.draw(batcher, &self.font, &self.game);
        self.flushUI(&ortho);

        // ── Build-menu icons (actual building sprites, atlas texture) ──
        if (self.panel.visible and self.atlas_loaded and self.atlas.uploaded) {
            batcher.begin();
            self.drawMenuIcons(batcher);
            if (batcher.sprite_count > 0) {
                self.atlas.setFilter(false); // nearest, crisp pixel art
                self.flushUITex(&ortho, self.atlas.gl_texture);
            }
        }

        // ── Minimap ──
        batcher.begin();
        self.minimap.draw(batcher, &self.shader);
        self.flushUI(&ortho);

        // ── Building ghost overlay (world-space, rendered through camera) ──
        self.building_placer.updateGhost(
            @floatCast(self.mouse_x),
            @floatCast(self.mouse_y),
            &self.camera,
            &self.game.state.map,
        );
        if (self.building_placer.active) {
            batcher.begin();
            const used_atlas = self.drawGhost(batcher);
            if (batcher.sprite_count > 0) {
                // Render through the camera (world-space). batcher.render sets
                // the correct projection/modelview and resets the batch.
                if (used_atlas) {
                    self.atlas.setFilter(false);
                    var atlas_tex = Texture{ .id = self.atlas.gl_texture, .width = texture_atlas_mod.ATLAS_SIZE, .height = texture_atlas_mod.ATLAS_SIZE };
                    batcher.render(&self.shader, &atlas_tex, &self.camera);
                } else {
                    var white_tex = Texture{ .id = fallback_tex, .width = 1, .height = 1 };
                    batcher.render(&self.shader, &white_tex, &self.camera);
                }
            }
        }

        // ── FPS counter ──
        batcher.begin();
        if (self.frame_count > 0) {
            self.font.drawFmt(batcher, "FPS: {d:.0}", .{self.fps}, self.view_w - 90, 2, .{ 0.7, 0.9, 1.0, 0.9 }, 0.6);
            self.font.drawFmt(batcher, "Tick: {}", .{self.game.state.tick}, self.view_w - 180, 2, .{ 0.7, 0.7, 0.7, 0.7 }, 0.6);
        }
        self.flushUI(&ortho);
    }

    pub fn close(self: *App) void {
        self.running = false;
        glfw.setWindowShouldClose(self.window, true);
    }
};

/// Read a file into an allocated buffer using POSIX/C API.
fn readFileToAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const c_path = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;

    // O_RDONLY = 0 on all POSIX platforms
    // O_RDONLY via default struct initialization (all flags false, ACCMODE defaults to RDONLY)
    const fd = @as(c_int, @intCast(std.c.open(@ptrCast(c_path.ptr), @as(std.c.O, .{}))));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    const size = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (size < 0) return error.SeekError;
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);

    const buf = try allocator.alloc(u8, @intCast(size));
    const read = std.c.read(fd, buf.ptr, @intCast(size));
    if (read < size) return error.ReadError;
    return buf;
}

// === GLFW Callbacks ===
var current_app: ?*App = null;

fn onWindowResize(window: *glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    // The size callback reports window (screen) coordinates; the GL viewport
    // needs framebuffer pixels (differs on HiDPI). Keep UI/camera in window
    // coords so they stay aligned with the cursor.
    const fb = glfw.getFramebufferSize(window);
    gl.viewport(0, 0, fb.width, fb.height);
    if (current_app) |app| app.setViewportSize(@floatFromInt(width), @floatFromInt(height));
}

fn onKey(_: *glfw.GLFWwindow, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (current_app) |app| {
        if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) app.close();
        if (key == 72 and action == glfw.GLFW_PRESS) app.show_hud = !app.show_hud;

        const p = action == glfw.GLFW_PRESS;
        const r = action == glfw.GLFW_RELEASE;
        if (key == glfw.GLFW_KEY_A or key == glfw.GLFW_KEY_LEFT) {
            app.scroll_left = p;
            app.scroll_right = r;
        }
        if (key == glfw.GLFW_KEY_D or key == glfw.GLFW_KEY_RIGHT) {
            app.scroll_right = p;
            app.scroll_left = r;
        }
        if (key == glfw.GLFW_KEY_W or key == glfw.GLFW_KEY_UP) {
            app.scroll_up = p;
            app.scroll_down = r;
        }
        if (key == glfw.GLFW_KEY_S or key == glfw.GLFW_KEY_DOWN) {
            app.scroll_down = p;
            app.scroll_up = r;
        }

        if (key >= glfw.GLFW_KEY_F1 and key <= glfw.GLFW_KEY_F9 and action == glfw.GLFW_PRESS) {
            const idx: usize = @intCast(key - glfw.GLFW_KEY_F1);
            // F1-F9 are shortcuts for the first nine build-menu entries, so the
            // keyboard and the on-screen menu always agree.
            if (idx < panel_mod.BUILD_MENU.len) {
                const b = panel_mod.BUILD_MENU[idx];
                app.panel.selected_building = b;
                app.building_placer.activate(b);
                app.panel.tool_mode = .place_building;
            }
        }

        // R = toggle road-building mode (click a flag, then a second flag).
        if (key == 82 and action == glfw.GLFW_PRESS) {
            if (app.road_builder.active) {
                app.road_builder.deactivate();
                app.panel.tool_mode = .none;
            } else {
                app.building_placer.deactivate();
                app.panel.selected_building = .none;
                app.road_builder.activate();
                app.panel.tool_mode = .build_road;
            }
        }

        // F10 = cancel current tool
        if (key == glfw.GLFW_KEY_F10 and action == glfw.GLFW_PRESS) {
            app.panel.selected_building = .none;
            app.building_placer.deactivate();
            app.road_builder.deactivate();
            app.panel.tool_mode = .none;
        }
    }
}

fn onMouseButton(_: *glfw.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (current_app) |app| {
        if (button == glfw.GLFW_MOUSE_BUTTON_LEFT) {
            if (action == glfw.GLFW_PRESS) {
                app.mouse_down = true;
                app.mouse_drag_start_x = app.mouse_x;
                app.mouse_drag_start_y = app.mouse_y;
                app.cam_drag_start_x = app.camera.x;
                app.cam_drag_start_y = app.camera.y;
            } else if (action == glfw.GLFW_RELEASE) {
                app.mouse_down = false;
                const dx = app.mouse_x - app.mouse_drag_start_x;
                const dy = app.mouse_y - app.mouse_drag_start_y;
                const is_click = (dx * dx + dy * dy) < 64.0;
                const mx: f32 = @floatCast(app.mouse_x);
                const my: f32 = @floatCast(app.mouse_y);

                // 1) Build-menu icon click → select that building + start placing.
                if (is_click and app.show_hud) {
                    if (app.panel.menuHit(mx, my)) |b| {
                        app.panel.selected_building = b;
                        app.panel.tool_mode = .place_building;
                        app.building_placer.activate(b);
                        return; // consumed — don't place / pan minimap
                    }
                }

                // 2) Road building: first click picks a start flag, second
                // click on another flag builds the road between them.
                if (is_click and app.road_builder.active) {
                    const tpos = app.mouseToTile();
                    if (!app.road_builder.has_start) {
                        _ = app.road_builder.tryStartAt(tpos, &app.game.state.map);
                    } else if (app.game.state.map.getTile(tpos).has_flag and !tpos.eql(app.road_builder.start_flag_pos)) {
                        // Recompute the path to the clicked flag, then build it.
                        app.road_builder.updatePath(tpos, &app.game.state.map);
                        _ = app.game.buildRoad(
                            app.road_builder.start_flag_pos,
                            tpos,
                            app.road_builder.path[0..app.road_builder.path_len],
                        );
                        app.road_builder.deactivate();
                        app.panel.tool_mode = .none;
                    }
                    return; // consumed
                }

                // 3) Placement click on the map.
                if (is_click and app.panel.tool_mode == .place_building and app.building_placer.active) {
                    _ = app.building_placer.tryPlace(&app.game, 0) catch null;
                }
                // 3) Minimap click (regardless of tool mode)
                if (app.minimap.visible and app.minimap.contains(mx, my)) {
                    const map_pos = app.minimap.pixelToMap(
                        mx,
                        my,
                        app.game.state.map.width,
                        app.game.state.map.height,
                    );
                    const tw: f32 = 32.0;
                    const hw: f32 = tw / 2.0;
                    const wx = @as(f32, @floatFromInt(map_pos.x)) * tw - @as(f32, @floatFromInt(map_pos.y)) * hw;
                    const wy = @as(f32, @floatFromInt(map_pos.y)) * 20.0;
                    app.camera.centerOn(wx, wy);
                    // Wrap camera to stay within map bounds
                    {
                        const mw2 = @as(f32, @floatFromInt(app.game.state.map.width)) * map_renderer_mod.TileWidth;
                        const mh2 = @as(f32, @floatFromInt(app.game.state.map.height)) * map_renderer_mod.TileHeight;
                        app.camera.wrap(mw2, mh2);
                    }
                }
            }
        }
        if (button == glfw.GLFW_MOUSE_BUTTON_RIGHT and action == glfw.GLFW_PRESS) {
            app.panel.selected_building = .none;
            app.building_placer.deactivate();
            app.road_builder.deactivate();
            app.panel.tool_mode = .none;
        }
    }
}

fn onCursorPos(_: *glfw.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (current_app) |app| {
        app.mouse_x = xpos;
        app.mouse_y = ypos;
        if (app.mouse_down) {
            const dx = @as(f32, @floatCast(xpos - app.mouse_drag_start_x));
            const dy = @as(f32, @floatCast(ypos - app.mouse_drag_start_y));
            app.camera.x = app.cam_drag_start_x - dx / app.camera.zoom;
            app.camera.y = app.cam_drag_start_y + dy / app.camera.zoom;
            // Wrap camera within map bounds for torus scrolling
            const mw = @as(f32, @floatFromInt(app.game.state.map.width)) * map_renderer_mod.TileWidth;
            const mh = @as(f32, @floatFromInt(app.game.state.map.height)) * map_renderer_mod.TileHeight;
            app.camera.wrap(mw, mh);
        }
        // Keep the road-building preview path in sync with the cursor.
        if (app.road_builder.active and app.road_builder.has_start) {
            app.road_builder.updatePath(app.mouseToTile(), &app.game.state.map);
        }
    }
}

fn onScroll(_: *glfw.GLFWwindow, _: f64, yoffset: f64) callconv(.c) void {
    if (current_app) |app| {
        if (yoffset > 0) {
            app.camera.zoomBy(1.1);
        } else if (yoffset < 0) {
            app.camera.zoomBy(1.0 / 1.1);
        }
    }
}
