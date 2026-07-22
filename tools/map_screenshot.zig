//! Map screenshot tool — renders a generated map to a BMP image so the
//! procedural terrain (and its per-seed variation) can be shown in a PR.
//!
//! Usage:
//!   map-screenshot --out path1.bmp --seed 1234
//!   map-screenshot --out path2.bmp           # random seed
//!   map-screenshot --out path.bmp --map-file world.zmap   # render a saved map
//!
//! Each tile is drawn as a single pixel (scaled up to a 8x8 block so the
//! 64x64 map becomes a 512x512 image). Colors come from the same fallback
//! palette used by the GL renderer when no game data is loaded.

const std = @import("std");
const core = @import("core");

const Map = core.map.Map;
const Terrain = core.map.Terrain;
const MapObject = core.map.MapObject;

/// Match the fallback colors in render/map_renderer.zig so the screenshots
/// look like what the player sees without game data. RGB triples (0..1)
/// scaled to 0..255.
fn terrainColor(t: Terrain) [3]u8 {
    return switch (t) {
        .water => .{ 51, 102, 204 }, // 0.2, 0.4, 0.8
        .grass => .{ 77, 179, 51 }, // 0.3, 0.7, 0.2
        .tundra => .{ 128, 153, 102 }, // 0.5, 0.6, 0.4
        .snow => .{ 230, 230, 255 }, // 0.9, 0.9, 1.0
        .swamp => .{ 77, 102, 51 }, // 0.3, 0.4, 0.2
        .lava => .{ 204, 77, 0 }, // 0.8, 0.3, 0.0
        .desert => .{ 204, 179, 51 }, // 0.8, 0.7, 0.2
        .mountain, .mountain2 => .{ 128, 102, 77 }, // 0.5, 0.4, 0.3
        .mountain_mined => .{ 153, 102, 51 },
        .mountain_flagged => .{ 128, 77, 25 },
    };
}

/// Darken a color by a brightness factor (height shading), clamped.
fn shade(c: [3]u8, brightness: f32) [3]u8 {
    const f = @max(0.0, @min(1.0, brightness));
    return .{
        @intFromFloat(@as(f32, @floatFromInt(c[0])) * f),
        @intFromFloat(@as(f32, @floatFromInt(c[1])) * f),
        @intFromFloat(@as(f32, @floatFromInt(c[2])) * f),
    };
}

/// Overlay an object marker so trees/rocks are visible in the screenshot.
fn withObjectColor(c: [3]u8, obj: MapObject) [3]u8 {
    return switch (obj) {
        .tree => .{ 30, 90, 30 }, // dark green dot
        .pine => .{ 20, 70, 40 }, // darker green
        .stone => .{ 90, 90, 95 }, // grey rock
        .none => c,
    };
}

/// Write a 24-bit (BGR, bottom-up) BMP file of `width`x`height` pixels.
fn writeBmp(path: []const u8, pixels: []const [3]u8, width: u32, height: u32) !void {
    const row_size: u32 = ((width * 3 + 3) / 4) * 4; // 4-byte aligned
    const pixel_bytes_size: u32 = row_size * height;
    const file_size: u32 = 54 + pixel_bytes_size;

    var hdr: [54]u8 = std.mem.zeroes([54]u8);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little); // pixel offset
    std.mem.writeInt(u32, hdr[14..18], 40, .little); // DIB header size
    std.mem.writeInt(i32, hdr[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, hdr[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little); // planes
    std.mem.writeInt(u16, hdr[28..30], 24, .little); // bpp
    std.mem.writeInt(u32, hdr[34..38], pixel_bytes_size, .little);

    const c_path = try std.heap.page_allocator.alloc(u8, path.len + 1);
    defer std.heap.page_allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;

    const fd: c_int = @intCast(std.c.open(@ptrCast(c_path.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    if (writeAllFd(fd, &hdr) < 0) return error.WriteError;

    // BMP rows are bottom-up. row_buf is zero-filled so the per-row
    // padding bytes (to a 4-byte boundary) are already 0.
    var y: u32 = height;
    while (y > 0) {
        y -= 1;
        var row_buf = std.heap.page_allocator.alloc(u8, row_size) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(row_buf);
        @memset(row_buf, 0);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const px = pixels[y * width + x];
            row_buf[x * 3 + 0] = px[2]; // B
            row_buf[x * 3 + 1] = px[1]; // G
            row_buf[x * 3 + 2] = px[0]; // R
        }
        if (writeAllFd(fd, row_buf) < 0) return error.WriteError;
    }
}

fn writeAllFd(fd: c_int, buf: []const u8) isize {
    var written: usize = 0;
    while (written < buf.len) {
        const w = std.c.write(fd, buf.ptr + written, buf.len - written);
        if (w < 0) return w;
        if (w == 0) return -1;
        written += @intCast(w);
    }
    return @intCast(written);
}

const Options = struct {
    out: []const u8 = "map.bmp",
    seed: ?u64 = null,
    map_file: ?[]const u8 = null,
    scale: u32 = 8,
};

fn parseArgs(args: std.process.Args, alloc: std.mem.Allocator) !Options {
    var it = std.process.Args.Iterator.initAllocator(args, alloc) catch return .{};
    defer it.deinit();
    var opts = Options{};
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            opts.out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const v = it.next() orelse return error.MissingValue;
            opts.seed = std.fmt.parseInt(u64, v, 10) catch
                std.fmt.parseInt(u64, v, 16) catch return error.InvalidSeed;
        } else if (std.mem.eql(u8, arg, "--map-file")) {
            opts.map_file = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const v = it.next() orelse return error.MissingValue;
            opts.scale = std.fmt.parseInt(u32, v, 10) catch return error.InvalidScale;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try parseArgs(init.args, alloc);

    var map = try Map.init(alloc, 64, 64);
    defer map.deinit();

    var seed: u64 = 0;
    if (opts.map_file) |path| {
        seed = try map.loadFromFile(path);
        std.debug.print("loaded map from {s} (seed={})\n", .{ path, seed });
    } else {
        // Random seed if none provided.
        if (opts.seed) |s| {
            seed = s;
        } else {
            var b: [8]u8 = undefined;
            const fd: c_int = @intCast(std.c.open("/dev/urandom", .{}));
            if (fd >= 0) {
                defer _ = std.c.close(fd);
                _ = std.c.read(fd, &b, b.len);
                seed = std.mem.readInt(u64, &b, .little);
            } else {
                var anchor: u8 = 0;
                seed = @intFromPtr(&anchor);
            }
        }
        map.generateTerrain(seed);
        std.debug.print("generated map (seed={})\n", .{seed});
    }

    // Build a 64x64 pixel buffer with terrain colors shaded by height.
    const w: u32 = map.width;
    const h: u32 = map.height;
    const small = try alloc.alloc([3]u8, w * h);
    for (0..h) |y| {
        for (0..w) |x| {
            const tile = map.getTileXY(@intCast(x), @intCast(y));
            var c = terrainColor(tile.terrain);
            // Brightness from height: low terrain darker, high terrain brighter.
            const height_f: f32 = @as(f32, @floatFromInt(tile.height)) / 15.0;
            const brightness: f32 = 0.65 + 0.45 * height_f;
            c = shade(c, brightness);
            c = withObjectColor(c, tile.object);
            small[y * w + x] = c;
        }
    }

    // Scale up to w*scale x h*scale.
    const sw = w * opts.scale;
    const sh = h * opts.scale;
    const big = try alloc.alloc([3]u8, sw * sh);
    for (0..sh) |y| {
        for (0..sw) |x| {
            const sx = x / opts.scale;
            const sy = y / opts.scale;
            big[y * sw + x] = small[sy * w + sx];
        }
    }

    try writeBmp(opts.out, big, sw, sh);
    std.debug.print("wrote {d}x{d} BMP to {s} (seed={})\n", .{ sw, sh, opts.out, seed });
}