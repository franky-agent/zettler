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

/// Search paths for game data files.
const data_paths = [_][]const u8{
    "data/spae.pa",
    "data/SPAE.PA",
    "../data/spae.pa",
    "../data/SPAE.PA",
    "SPAE.PA",
};

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("Freeserf Zig — First Playable Build\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse command-line flags. Supported:
    //   --seed <u64>         fix the procedural terrain seed
    //   --map-file <path>    load a .zmap file instead of generating a map
    //   --save-map <path>    write the generated/loaded map to this path
    //   --help, -h           show usage
    const opts = parseArgs(allocator, init.args) catch |err| {
        std.debug.print("error parsing arguments: {}\n", .{err});
        printUsage();
        return;
    };
    if (opts.help) {
        printUsage();
        return;
    }

    // Try GLFW first, fall back to terminal demo
    const app_result = runGlfwDemo(allocator, opts);
    if (app_result) |_| {} else |_| {
        try runTerminalDemo(allocator, opts);
    }
}

fn runGlfwDemo(allocator: std.mem.Allocator, opts: CliOptions) !void {
    std.debug.print("Initializing...\n", .{});

    var app = try App.init(allocator, .{
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

/// Parsed command-line options. `help` short-circuits main and prints usage.
const CliOptions = struct {
    seed: ?u64 = null,
    map_file: ?[]const u8 = null,
    save_map: ?[]const u8 = null,
    help: bool = false,
};

/// Minimal hand-rolled flag parser. Recognises `--seed <value>`,
/// `--map-file <path>`, `--save-map <path>`, and `--help`/`-h`.
/// Unknown flags are ignored so the game still boots with stray args.
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !CliOptions {
    var it = std.process.Args.Iterator.initAllocator(args, allocator) catch |err| {
        // If the platform requires initAllocator and it fails, fall back to
        // init() (POSIX). Both branches return a usable iterator.
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
        }
        // Unknown args are ignored.
    }

    return opts;
}

fn printUsage() void {
    const out = std.debug.print;
    out(
        \\Usage: freeserf [options]
        \\
        \\Options:
        \\  --seed <u64>         Fix the procedural terrain seed. Without this,
        \\                      a random world is generated on every startup.
        \\  --map-file <path>   Load a .zmap file (created with --save-map)
        \\                      instead of generating a new map.
        \\  --save-map <path>   Write the current map to this path so it can
        \\                      be replayed later with --map-file.
        \\  -h, --help          Show this help and exit.
        \\
        \\Examples:
        \\  freeserf --seed 1234 --save-map world.zmap
        \\  freeserf --map-file world.zmap
        \\
    , .{});
}

fn setupDemoScene(app: *App) !void {
    const p0: u8 = 0;
    const cx: u16 = 32;
    const cy: u16 = 32;
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

    var game = try Game.init(allocator, 64, 64, 1, .{
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

    const cx: u16 = 32;
    const cy: u16 = 32;
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
