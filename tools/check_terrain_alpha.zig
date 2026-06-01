const std = @import("std");
const data = @import("data");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const raw = readFileToAlloc(a, "data/SPAE.PA") catch return;
    defer a.free(raw);
    var pak = data.PakFile.init(a, raw) catch return;
    defer pak.deinit();

    // Load palette with index 0 = transparent
    var decoder = data.BmpDecoder.init(a);
    const pal_data = pak.getFile(2) catch return;
    if (pal_data.len >= 768) {
        var pal: [256]data.bmp.ColorRGBA = undefined;
        for (0..256) |i| {
            pal[i] = data.bmp.ColorRGBA{
                .r = if (i == 0) 0 else pal_data[i * 3],
                .g = if (i == 0) 0 else pal_data[i * 3 + 1],
                .b = if (i == 0) 0 else pal_data[i * 3 + 2],
                .a = if (i == 0) 0 else 255,
            };
        }
        decoder.setPalette(pal);
    }

    // Check terrain sprites 260-265: do they have palette index 0 in corners?
    for (260..266) |idx| {
        const d = try pak.getFile(@intCast(idx));
        if (d.len < 10) continue;
        const w: u32 = std.mem.readInt(u16, d[2..4], .little);
        const h: u32 = std.mem.readInt(u16, d[4..6], .little);
        
        var sprite = try decoder.decode(d);
        defer sprite.deinit(a);

        // Show every row as text: T=transparent, .=opaque
        std.debug.print("=== Sprite [{d}] {d}x{d} ===\n", .{idx, w, h});
        for (0..h) |y| {
            std.debug.print("  row {d:2}: ", .{y});
            for (0..w) |x| {
                const px = sprite.getPixel(@intCast(x), @intCast(y));
                if (px.a == 0) {
                    std.debug.print("  ", .{});
                } else if (px.r > 200 and px.g > 200 and px.b > 200) {
                    std.debug.print("..", .{});
                } else {
                    // show as two hex chars
                    std.debug.print("{x:0>2}", .{@as(u8, @intCast(px.r >> 4))});
                }
            }
            std.debug.print("\n", .{});
        }
    }
}

fn readFileToAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const c_path = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
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
