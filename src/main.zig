//! Freeserf — a free reimplementation of The Settlers (1993).
//!
//! First playable build: loads SPAE.PA game data, renders the map
//! with real terrain sprites, shows buildings, and handles input.

const std = @import("std");
const core = @import("core");
const render = @import("render");

const App = render.App;
const AppOptions = render.AppOptions;
const Game = core.game.Game;
const Resource = core.Resource;
const Building = core.Building;
const MapPos = core.types.MapPos;
const MapMinSize = core.map.MIN_SIZE;
const MapMaxSize = core.map.MAX_SIZE;

/// Default map dimensions (the classic Settlers map size).
const DEFAULT_MAP_W: u16 = 64;
const DEFAULT_MAP_H: u16 = 64;

/// Search paths for game data files.
const data_paths = [_][]const u8{
    "data/spae.pa",
    "data/SPAE.PA",
    "../data/spae.pa",
    "../data/SPAE.PA",
    "SPAE.PA",
};

/// Parsed command-line options. `help` short-circuits main and prints usage.
///
/// Map-size flags (`--map-size`, `--map-w`, `--map-h`) control the dimensions
/// of a freshly generated map (clamped to [MapMinSize, MapMaxSize]). They are
/// ignored when `map_file` is set — a loaded map keeps its stored dimensions.
const CliOptions = struct {
    map_w: u16 = DEFAULT_MAP_W,
    map_h: u16 = DEFAULT_MAP_H,
    seed: ?u64 = null,
    map_file: ?[]const u8 = null,
    save_map: ?[]const u8 = null,
    help: bool = false,
};

/// Parse command-line arguments.
///
/// Map-size flags:
///   --map-size <W> <H>    e.g. --map-size 256 256
///   --map-size=WxH          e.g. --map-size=256x256  (also accepts 'X')
///   --map-w <W> --map-h <H>
///
/// Seed / persistence flags:
///   --seed <u64>         fix the procedural terrain seed
///   --map-file <path>    load a .zmap file instead of generating a map
///   --save-map <path>    write the generated/loaded map to this path
///   --help, -h           show usage
///
/// On malformed map-size input a message is printed to stderr and the default
/// (64×64) is kept. Missing values for --seed/--map-file/--save-map return
/// `error.MissingValue`; invalid --seed returns `error.InvalidSeed`.
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !CliOptions {
    var it = std.process.Args.Iterator.initAllocator(args, allocator) catch |err| {
        // If initAllocator fails (e.g. OOM on WASI/Windows), there is nothing
        // we can safely do — return defaults.
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{};
    };
    defer it.deinit();

    var opts = CliOptions{};

    // Skip argv[0] (program name).
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const val = it.next() orelse return error.MissingValue;
            opts.seed = std.fmt.parseInt(u64, val, 10) catch
                std.fmt.parseInt(u64, val, 16) catch return error.InvalidSeed;
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            opts.map_file = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--save-map")) {
            opts.save_map = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--map-size")) {
            // Parse both values into temporaries and only commit to `opts`
            // when both succeed, so a bad height does not leave a lopsided
            // (w, default-h) map behind.
            const w_str = it.next() orelse {
                std.debug.print("--map-size requires <width> <height>\n", .{});
                continue;
            };
            const h_str = it.next() orelse {
                std.debug.print("--map-size requires <width> <height>\n", .{});
                continue;
            };
            if (looksLikeFlag(w_str) or looksLikeFlag(h_str)) {
                std.debug.print("--map-size: '{s}' / '{s}' look like flags, not sizes\n", .{ w_str, h_str });
                continue;
            }
            const w = std.fmt.parseInt(u16, w_str, 10) catch {
                std.debug.print("Invalid map width '{s}'\n", .{w_str});
                continue;
            };
            const h = std.fmt.parseInt(u16, h_str, 10) catch {
                std.debug.print("Invalid map height '{s}'\n", .{h_str});
                continue;
            };
            opts.map_w = w;
            opts.map_h = h;
        } else if (std.mem.startsWith(u8, arg, "--map-size=")) {
            const rest = arg["--map-size=".len..];
            // Accept both 'x' and 'X' as the width/height separator.
            const sep = std.mem.indexOfScalar(u8, rest, 'x') orelse
                std.mem.indexOfScalar(u8, rest, 'X');
            if (sep) |s| {
                const w = std.fmt.parseInt(u16, rest[0..s], 10) catch {
                    std.debug.print("Invalid map size '{s}'\n", .{rest});
                    continue;
                };
                const h = std.fmt.parseInt(u16, rest[s + 1 ..], 10) catch {
                    std.debug.print("Invalid map size '{s}'\n", .{rest});
                    continue;
                };
                opts.map_w = w;
                opts.map_h = h;
            } else {
                std.debug.print("--map-size=WxH: missing 'x' separator in '{s}'\n", .{rest});
            }
        } else if (std.mem.eql(u8, arg, "--map-w")) {
            const w_str = it.next() orelse {
                std.debug.print("--map-w requires a width\n", .{});
                continue;
            };
            if (looksLikeFlag(w_str)) {
                std.debug.print("--map-w: '{s}' looks like a flag, not a width\n", .{w_str});
                continue;
            }
            if (std.fmt.parseInt(u16, w_str, 10)) |w| {
                opts.map_w = w;
            } else |_| {
                std.debug.print("Invalid map width '{s}'\n", .{w_str});
            }
        } else if (std.mem.eql(u8, arg, "--map-h")) {
            const h_str = it.next() orelse {
                std.debug.print("--map-h requires a height\n", .{});
                continue;
            };
            if (looksLikeFlag(h_str)) {
                std.debug.print("--map-h: '{s}' looks like a flag, not a height\n", .{h_str});
                continue;
            }
            if (std.fmt.parseInt(u16, h_str, 10)) |h| {
                opts.map_h = h;
            } else |_| {
                std.debug.print("Invalid map height '{s}'\n", .{h_str});
            }
        }
        // Unknown args are ignored.
    }

    // Clamp map size to the supported range and report when the requested
    // size was adjusted. (Ignored when loading a .zmap — the file's stored
    // dimensions take precedence.)
    const orig_w = opts.map_w;
    const orig_h = opts.map_h;
    opts.map_w = @max(MapMinSize, @min(MapMaxSize, opts.map_w));
    opts.map_h = @max(MapMinSize, @min(MapMaxSize, opts.map_h));
    if (opts.map_w != orig_w or opts.map_h != orig_h) {
        std.debug.print(
            "Map size {d}x{d} is outside the supported range, clamped to {d}x{d}\n",
            .{ orig_w, orig_h, opts.map_w, opts.map_h },
        );
    }
    return opts;
}

/// Heuristic: a token starting with "--" is treated as a flag, not a value.
/// Prevents `--map-size 256 --fullscreen` from eating `--fullscreen` as the
/// height argument.
fn looksLikeFlag(s: []const u8) bool {
    return s.len >= 2 and s[0] == '-' and s[1] == '-';
}

fn printUsage() void {
    std.debug.print(
        \\Usage: freeserf [options]
        \\
        \\Options:
        \\  --map-size <W> <H>   Set the map size (e.g. --map-size 256 256).
        \\  --map-size=WxH        Set the map size (e.g. --map-size=256x256).
        \\  --map-w <W>           Set the map width.
        \\  --map-h <H>           Set the map height.
        \\  --seed <u64>          Fix the procedural terrain seed. Without this,
        \\                       a random world is generated on every startup.
        \\  --map-file <path>     Load a .zmap file (created with --save-map)
        \\                       instead of generating a new map.
        \\  --save-map <path>     Write the current map to this path so it can
        \\                       be replayed later with --map-file.
        \\  -h, --help            Show this help and exit.
        \\
        \\Map sizes from {d}x{d} to {d}x{d} are supported.
        \\
        \\Examples:
        \\  freeserf --map-size 256 256 --seed 1234 --save-map world.zmap
        \\  freeserf --map-file world.zmap
        \\
    , .{ MapMinSize, MapMinSize, MapMaxSize, MapMaxSize });
}

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("Freeserf Zig — First Playable Build\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opts = parseArgs(allocator, init.args) catch |err| {
        std.debug.print("error parsing arguments: {}\n", .{err});
        printUsage();
        return;
    };
    if (opts.help) {
        printUsage();
        return;
    }
    std.debug.print("Map size: {d}x{d}\n", .{ opts.map_w, opts.map_h });

    // Try GLFW first, fall back to terminal demo
    const app_result = runGlfwDemo(allocator, opts);
    if (app_result) |_| {} else |_| {
        try runTerminalDemo(allocator, opts);
    }
}

fn runGlfwDemo(allocator: std.mem.Allocator, opts: CliOptions) !void {
    std.debug.print("Initializing...\n", .{});

    var app = try App.init(allocator, opts.map_w, opts.map_h, .{
        .seed = opts.seed,
        .map_file = opts.map_file,
        .save_map = opts.save_map,
    });
    errdefer app.deinit();

    // Load game data (before OpenGL context — just file reading)
    std.debug.print("Loading game data...\n", .{});
    const data_loaded = try app.loadGameData(&data_paths);
    if (!data_loaded) {
        std.debug.print("  No game data found — using fallback colors.\n", .{});
    }

    try setupDemoScene(&app);
    try app.createWindow();
    errdefer {
        app.deinit();
        render.glfw.terminate();
    }

    // Build texture atlas AFTER OpenGL context is created
    if (data_loaded) {
        std.debug.print("Building texture atlas...\n", .{});
        app.buildAtlas() catch |e| {
            std.debug.print("  Atlas build failed: {}\n", .{e});
        };
    }

    app.running = true;
    std.debug.print("Window created. Running game loop...\n", .{});
    app.run() catch |e| {
        std.debug.print("Game loop error: {}\n", .{e});
    };

    app.deinit();
    render.glfw.terminate();
    std.debug.print("Demo complete.\n", .{});
}

fn setupDemoScene(app: *App) !void {
    const p0: u8 = 0;
    // Place the starter cluster around the map center so it is visible no
    // matter what map size was selected at startup.
    const cx: u16 = app.game.state.map.width / 2;
    const cy: u16 = app.game.state.map.height / 2;
    const game = &app.game;

    const positions = [_]MapPos{
        .{ .x = cx + 3, .y = cy },
        .{ .x = cx, .y = cy + 3 },
        .{ .x = cx, .y = cy },
        .{ .x = cx + 2, .y = cy + 2 },
        .{ .x = cx - 3, .y = cy },
        .{ .x = cx + 1, .y = cy - 2 },
        .{ .x = cx - 2, .y = cy + 1 },
        .{ .x = cx + 2, .y = cy - 1 },
        .{ .x = cx - 1, .y = cy + 2 },
    };
    for (positions) |pos| {
        game.state.map.getTile(pos).terrain = .grass;
    }

    const building_types = [_]Building{
        .lumberjack, .fisher,     .stock,
        .sawmill,    .forester,   .farm,
        .tower,      .stonecutter, .mill,
    };

    for (building_types, 0..) |btype, i| {
        if (i < positions.len) {
            const idx = (try game.placeBuilding(positions[i], btype, p0)) orelse continue;
            const building = game.state.buildings.get(idx);
            building.is_done = true;
            if (btype.isProducer()) {
                building.serf_index = .{ .index = @intCast(i) };
            }
        }
    }

    const p = &game.state.players.players[0];
    p.resources[@intFromEnum(Resource.wood)] = 20;
    p.resources[@intFromEnum(Resource.stone)] = 10;
    p.resources[@intFromEnum(Resource.planks)] = 15;
    p.resources[@intFromEnum(Resource.fish)] = 8;
    p.resources[@intFromEnum(Resource.bread)] = 6;
    p.resources[@intFromEnum(Resource.iron)] = 4;
    p.resources[@intFromEnum(Resource.coal)] = 3;
    p.resources[@intFromEnum(Resource.beer)] = 2;

    std.debug.print("  Scene: {} buildings\n", .{building_types.len});
}

fn runTerminalDemo(allocator: std.mem.Allocator, opts: CliOptions) !void {
    const out = std.debug.print;
    out("No display — terminal demo.\n", .{});

    var game = try Game.init(allocator, opts.map_w, opts.map_h, 1, .{
        .seed = opts.seed,
        .map_file = opts.map_file,
    });
    defer game.deinit();
    out("  Map seed: {}\n", .{game.map_seed});

    // Optionally persist the map for later replay.
    if (opts.save_map) |path| {
        if (game.state.map.saveToFile(path, game.map_seed)) |_| {
            out("  Map saved to {s}\n", .{path});
        } else |err| {
            out("  Warning: could not save map to '{s}': {}\n", .{ path, err });
        }
    }

    const cx: u16 = opts.map_w / 2;
    const cy: u16 = opts.map_h / 2;
    const positions = [_]MapPos{
        .{ .x = cx + 3, .y = cy }, .{ .x = cx, .y = cy + 3 },
        .{ .x = cx, .y = cy }, .{ .x = cx + 2, .y = cy + 2 },
        .{ .x = cx - 3, .y = cy },
    };
    for (positions) |pos| game.state.map.getTile(pos).terrain = .grass;

    _ = try game.placeBuilding(positions[0], .lumberjack, 0);
    _ = try game.placeBuilding(positions[1], .fisher, 0);
    _ = try game.placeBuilding(positions[2], .stock, 0);
    _ = try game.placeBuilding(positions[3], .sawmill, 0);
    _ = try game.placeBuilding(positions[4], .forester, 0);

    const p = &game.state.players.players[0];
    p.resources[@intFromEnum(Resource.wood)] = 10;
    p.resources[@intFromEnum(Resource.stone)] = 5;
    p.resources[@intFromEnum(Resource.planks)] = 8;
    p.resources[@intFromEnum(Resource.fish)] = 6;

    var tick: u64 = 0;
    while (tick < 1000) : (tick += 1) {
        game.tick(tick);
        if (tick > 0 and tick % 50 == 0) {
            out("[T={}] Wood:{} Planks:{} Stone:{} Fish:{} Bldgs:{}\n", .{
                game.state.tick,
                p.resources[@intFromEnum(Resource.wood)],
                p.resources[@intFromEnum(Resource.planks)],
                p.resources[@intFromEnum(Resource.stone)],
                p.resources[@intFromEnum(Resource.fish)],
                game.state.buildings.buildings.items.len,
            });
        }
    }
    out("\nTerminal demo complete.\n", .{});
}