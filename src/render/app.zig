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
    selected_building: Building = .none,
    show_hud: bool = true,

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
        gl.viewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
        gl.clearColor(0.4, 0.6, 0.8, 1.0);

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
            self.renderWaves(const_tick);
            self.renderBuildings();

            // Render HUD overlay
            if (self.show_hud and frames > 0) {
                self.renderHUD();
            }

            glfw.swapBuffers(self.window);
            self.frame_count += 1;
            frames += 1;

            if (frames == 1) std.debug.print("  frame 1 ok\n", .{});
        }
        std.debug.print("  run done: {} frames\n", .{frames});
    }

    fn handleInput(self: *App) void {
        const speed = self.scroll_speed / 60.0;
        if (self.scroll_left) self.camera.pan(-speed, 0);
        if (self.scroll_right) self.camera.pan(speed, 0);
        if (self.scroll_up) self.camera.pan(0, -speed);
        if (self.scroll_down) self.camera.pan(0, speed);
    }

    const BuildingOrder = struct { index: usize, baseline: f32 };

    fn renderBuildings(self: *App) void {
        const batcher = &self.sprite_batcher;
        const cam = &self.camera;
        const tw: f32 = map_renderer_mod.TileWidth;
        const th: f32 = map_renderer_mod.TileHeight;
        const hw: f32 = tw / 2.0;
        const items = self.game.state.buildings.buildings.items;

        batcher.begin();

        // Sort completed buildings back-to-front by screen baseline so nearer
        // (lower-on-screen) buildings and their shadows occlude farther ones.
        const order = std.heap.page_allocator.alloc(BuildingOrder, items.len) catch null;
        defer if (order) |o| std.heap.page_allocator.free(o);
        if (order) |o| {
            var n: usize = 0;
            for (items, 0..) |*b, i| {
                if (!b.is_done) continue;
                const bh: f32 = @floatFromInt(self.game.state.map.getTile(b.pos).height);
                const wy = @as(f32, @floatFromInt(b.pos.y)) * th -
                    map_renderer_mod.HEIGHT_SCALE * bh;
                o[n] = .{ .index = i, .baseline = wy };
                n += 1;
            }
            std.mem.sort(BuildingOrder, o[0..n], {}, struct {
                fn lt(_: void, a: BuildingOrder, c: BuildingOrder) bool {
                    return a.baseline < c.baseline;
                }
            }.lt);
            for (o[0..n]) |e| self.drawBuilding(batcher, &items[e.index], tw, th, hw);
        } else {
            // Allocation failed: draw unsorted (still correct, just possible overlap).
            for (items) |*b| {
                if (!b.is_done) continue;
                self.drawBuilding(batcher, b, tw, th, hw);
            }
        }

        if (self.atlas_loaded and self.atlas.uploaded) {
            var atlas_tex = Texture{ .id = self.atlas.gl_texture, .width = texture_atlas_mod.ATLAS_SIZE, .height = texture_atlas_mod.ATLAS_SIZE };
            batcher.render(&self.shader, &atlas_tex, cam);
        } else {
            var white_tex = Texture{ .id = fallback_tex, .width = 1, .height = 1 };
            batcher.render(&self.shader, &white_tex, cam);
        }
    }

    /// Queue one building into the sprite batcher: its semi-transparent shadow
    /// first (underneath), then the building sprite, both placed at the building's
    /// map pixel + the sprite's own hotspot offset (matches the original use_off,
    /// keeps shadow and building aligned). Falls back to a colored rectangle when
    /// no sprite is available.
    fn drawBuilding(self: *App, batcher: *SpriteBatcher, b: anytype, tw: f32, th: f32, hw: f32) void {
        const bh: f32 = @floatFromInt(self.game.state.map.getTile(b.pos).height);
        const wx = @as(f32, @floatFromInt(b.pos.x)) * tw -
            @as(f32, @floatFromInt(b.pos.y)) * hw;
        const wy = @as(f32, @floatFromInt(b.pos.y)) * th -
            map_renderer_mod.HEIGHT_SCALE * bh;

        const sid = if (self.atlas_loaded and self.atlas.uploaded)
            sprite_ids.Building.fromGameBuilding(b.building_type)
        else
            null;

        if (sid) |sprite_id| {
            if (self.atlas.get(sprite_id)) |entry| {
                // Shadow (PAK building id + 250), drawn under the building.
                if (self.atlas.get(sprite_id + 250)) |sh| {
                    batcher.add(.{
                        .x = wx + @as(f32, @floatFromInt(sh.off_x)),
                        .y = wy + @as(f32, @floatFromInt(sh.off_y)),
                        .width = @floatFromInt(sh.pixel_w),
                        .height = @floatFromInt(sh.pixel_h),
                        .u = sh.u, .v = sh.v, .uw = sh.uw, .vh = sh.vh,
                        .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0,
                    });
                }
                // Building sprite at its hotspot offset.
                batcher.add(.{
                    .x = wx + @as(f32, @floatFromInt(entry.off_x)),
                    .y = wy + @as(f32, @floatFromInt(entry.off_y)),
                    .width = @floatFromInt(entry.pixel_w),
                    .height = @floatFromInt(entry.pixel_h),
                    .u = entry.u, .v = entry.v, .uw = entry.uw, .vh = entry.vh,
                    .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0,
                });
                return;
            }
        }

        // Fallback: colored rectangle.
        const c = buildingColor(b.building_type);
        batcher.add(.{
            .x = wx - hw,
            .y = wy - th,
            .width = tw,
            .height = th * 2,
            .u = 0, .v = 0, .uw = 0, .vh = 0,
            .r = c[0], .g = c[1], .b = c[2], .a = 0.9,
        });
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
            fn at(m: *core.map.Map, x: usize, y: usize) bool {
                if (x >= m.width or y >= m.height) return false;
                return m.getTileXY(@intCast(x), @intCast(y)).terrain == .water;
            }
        }.at;

        batcher.begin();
        var drew = false;
        for (0..map.height) |yy| {
            for (0..map.width) |xx| {
                const tile = map.getTileXY(@intCast(xx), @intCast(yy));
                if (tile.terrain != .water) continue;
                // Skip shoreline tiles to avoid waves spilling onto land.
                if (!isWater(map, xx + 1, yy) or !isWater(map, xx, yy + 1) or
                    !isWater(map, xx + 1, yy + 1)) continue;
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

    fn renderHUD(self: *App) void {
        const cam = &self.camera;
        const batcher = &self.sprite_batcher;
        batcher.begin();

        // Resource bars: label strip left (16px) + value bar right (max 140px).
        const resources = [_]struct { idx: usize, c: [3]f32, name: []const u8 }{
            .{ .idx = @intFromEnum(Resource.wood), .c = .{ 0.30, 0.60, 0.20 }, .name = "Wood" },
            .{ .idx = @intFromEnum(Resource.planks), .c = .{ 0.60, 0.40, 0.20 }, .name = "Planks" },
            .{ .idx = @intFromEnum(Resource.stone), .c = .{ 0.50, 0.50, 0.50 }, .name = "Stone" },
            .{ .idx = @intFromEnum(Resource.fish), .c = .{ 0.20, 0.40, 0.80 }, .name = "Fish" },
            .{ .idx = @intFromEnum(Resource.bread), .c = .{ 0.80, 0.70, 0.20 }, .name = "Bread" },
            .{ .idx = @intFromEnum(Resource.iron), .c = .{ 0.70, 0.30, 0.10 }, .name = "Iron" },
            .{ .idx = @intFromEnum(Resource.coal), .c = .{ 0.25, 0.25, 0.25 }, .name = "Coal" },
            .{ .idx = @intFromEnum(Resource.beer), .c = .{ 0.80, 0.60, 0.10 }, .name = "Beer" },
        };
        const MAX_BAR_W: f32 = 140;
        const MAX_RESOURCE: f32 = 50.0; // scale: 50 units = full bar
        const ROW_H: f32 = 28;
        const TOP_PAD: f32 = 8;
        const panel_w: f32 = 168;
        const panel_h: f32 = TOP_PAD + @as(f32, @floatFromInt(resources.len)) * ROW_H + 8;

        // HUD panel background — sized to fit resource rows exactly
        batcher.add(.{
            .x = 0,
            .y = 0,
            .width = panel_w,
            .height = panel_h,
            .u = 0,
            .v = 0,
            .uw = 0,
            .vh = 0,
            .r = 0.12,
            .g = 0.12,
            .b = 0.18,
            .a = 0.88,
        });

        const p = &self.game.state.players.players[0];
        for (resources, 0..) |r, i| {
            const ry: f32 = TOP_PAD + @as(f32, @floatFromInt(i)) * ROW_H;
            const amount: f32 = @floatFromInt(p.resources[r.idx]);
            const bar_w: f32 = @min(amount / MAX_RESOURCE * MAX_BAR_W, MAX_BAR_W);
            // Track background (dark)
            batcher.add(.{
                .x = 16,
                .y = ry + 4,
                .width = MAX_BAR_W,
                .height = ROW_H - 8,
                .u = 0,
                .v = 0,
                .uw = 0,
                .vh = 0,
                .r = 0.05,
                .g = 0.05,
                .b = 0.08,
                .a = 1.0,
            });
            // Value bar (colored, scaled by actual amount)
            if (bar_w > 0) {
                batcher.add(.{
                    .x = 16,
                    .y = ry + 4,
                    .width = bar_w,
                    .height = ROW_H - 8,
                    .u = 0,
                    .v = 0,
                    .uw = 0,
                    .vh = 0,
                    .r = r.c[0],
                    .g = r.c[1],
                    .b = r.c[2],
                    .a = 0.85,
                });
            }
            // Color chip (left side)
            batcher.add(.{
                .x = 2,
                .y = ry + 4,
                .width = 12,
                .height = ROW_H - 8,
                .u = 0,
                .v = 0,
                .uw = 0,
                .vh = 0,
                .r = r.c[0],
                .g = r.c[1],
                .b = r.c[2],
                .a = 1.0,
            });
        }

        // Render HUD with screen-space orthographic projection.
        // Map (0,0)=top-left → (WINDOW_WIDTH, WINDOW_HEIGHT)=bottom-right so
        // HUD layout code can use familiar screen coordinates.
        var ortho: [16]f32 = undefined;
        {
            const w: f32 = @floatFromInt(WINDOW_WIDTH);
            const h: f32 = @floatFromInt(WINDOW_HEIGHT);
            var m: core.Mat4 = .{};
            m.data[0] = 2.0 / w;
            m.data[5] = -2.0 / h; // negative: flip Y so top=0
            m.data[12] = -1.0;
            m.data[13] = 1.0; // shift so y=0 maps to NDC top (+1)
            ortho = m.data;
        }
        const mv: [16]f32 = (core.Mat4{}).data;

        // Bind the white fallback texture so solid-color HUD quads
        // (which use uw=0/vh=0 and sample UV 0,0) appear in their vertex color
        // instead of sampling a transparent pixel from the sprite atlas.
        gl.bindTexture(gl.GL_TEXTURE_2D, fallback_tex);
        self.shader.use();
        self.shader.setTexture(0);
        self.shader.setColor(1, 1, 1, 1);
        self.shader.setOffset(0, 0);
        self.shader.setProjection(&ortho);
        self.shader.setModelview(&mv);

        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.sprite_batcher.ibo);
        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.sprite_batcher.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(self.sprite_batcher.vertices[0 .. self.sprite_batcher.sprite_count * 4]), gl.GL_DYNAMIC_DRAW);

        const stride: i32 = @sizeOf(sprite_batcher_mod.SpriteVertex);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 8);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 16);
        gl.drawElements(gl.GL_TRIANGLES, @intCast(self.sprite_batcher.sprite_count * 6), gl.GL_UNSIGNED_SHORT, 0);
        gl.disableVertexAttribArray(0);
        gl.disableVertexAttribArray(1);
        gl.disableVertexAttribArray(2);

        cam.updateMatrices();
        self.sprite_batcher.sprite_count = 0;
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

fn onWindowResize(_: *glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    gl.viewport(0, 0, width, height);
    if (current_app) |app| app.camera.setViewportSize(@floatFromInt(width), @floatFromInt(height));
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
            const idx = key - glfw.GLFW_KEY_F1;
            if (idx <= 8) {
                const buildings = [_]Building{
                    .lumberjack, .stonecutter, .fisher, .forester,
                    .sawmill,    .farm,        .mill,   .tower,
                    .stock,
                };
                app.selected_building = buildings[@intCast(idx)];
            }
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
            }
        }
        if (button == glfw.GLFW_MOUSE_BUTTON_RIGHT and action == glfw.GLFW_PRESS) {
            app.selected_building = .none;
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
            app.camera.matrices_dirty = true;
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
