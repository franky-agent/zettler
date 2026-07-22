const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var map = try core.map.Map.init(alloc, 64, 64);
    defer map.deinit();
    map.generateTerrain(42);
    var water: usize = 0;
    var grass: usize = 0;
    var tundra: usize = 0;
    var snow: usize = 0;
    var other: usize = 0;
    var hcount: [16]usize = @splat(0);
    for (0..map.height) |y| {
        for (0..map.width) |x| {
            const t = map.getTileXY(@intCast(x), @intCast(y));
            hcount[t.height] += 1;
            switch (t.terrain) {
                .water => water += 1,
                .grass => grass += 1,
                .tundra => tundra += 1,
                .snow => snow += 1,
                else => other += 1,
            }
        }
    }
    const total: usize = @intCast(map.width * map.height);
    const out = std.debug.print;
    out("Total tiles: {}\n", .{total});
    out("Water: {} ({d:.1}%)\n", .{ water, @as(f64, @floatFromInt(water)) / @as(f64, @floatFromInt(total)) * 100 });
    out("Grass: {} ({d:.1}%)\n", .{ grass, @as(f64, @floatFromInt(grass)) / @as(f64, @floatFromInt(total)) * 100 });
    out("Tundra: {} ({d:.1}%)\n", .{ tundra, @as(f64, @floatFromInt(tundra)) / @as(f64, @floatFromInt(total)) * 100 });
    out("Snow: {} ({d:.1}%)\n", .{ snow, @as(f64, @floatFromInt(snow)) / @as(f64, @floatFromInt(total)) * 100 });
    out("Other: {} ({d:.1}%)\n", .{ other, @as(f64, @floatFromInt(other)) / @as(f64, @floatFromInt(total)) * 100 });
    out("\nHeight histogram (0-15):\n", .{});
    for (hcount, 0..) |c, i| {
        if (c > 0) out("  h{}: {} tiles\n", .{ i, c });
    }
}