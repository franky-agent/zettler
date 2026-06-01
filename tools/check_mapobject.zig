const std = @import("std");
const data = @import("data");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const path = "data/SPAE.PA";
    const raw = readFileToAlloc(a, path) catch { std.debug.print("not found\n", .{}); return; };
    defer a.free(raw);
    var pak = data.PakFile.init(a, raw) catch |e| { std.debug.print("PAK error: {}\n", .{e}); return; };
    defer pak.deinit();

    // C++ freeserf: AssetMapObject starts at PAK index 1250.
    // map_building_sprite[] uses hex offsets from there.
    const MAP_OBJECT_BASE: u16 = 1250;
    const hex_offsets = [_]u16{ 0, 0xa7, 0xa8, 0xae, 0xa9, 0xa3, 0xa4, 0xa5, 0xa6, 0xaa, 0xc0, 0xab, 0x9a, 0x9c, 0x9b, 0xbc, 0xa2, 0xa0, 0xa1, 0x99, 0x9d, 0x9e, 0x98, 0x9f, 0xb2 };
    const type_names = [_][]const u8{ "None", "Fisher", "Lumberjack", "Boatbuilder", "Stonecutter", "StoneMine", "CoalMine", "IronMine", "GoldMine", "Forester", "Stock", "Hut", "Farm", "Butcher", "PigFarm", "Mill", "Baker", "Sawmill", "SteelSmelter", "ToolMaker", "WeaponSmith", "Tower", "Fortress", "GoldSmelter", "Castle" };

    std.debug.print("=== C++ freeserf map_building_sprite (AssetMapObject base={}) ===\n", .{MAP_OBJECT_BASE});
    for (hex_offsets, 0..) |offset, i| {
        if (i == 0) continue;
        const actual_idx = MAP_OBJECT_BASE + offset;
        const d = pak.getFile(actual_idx) catch {
            std.debug.print("  {s:>13} (type={d:2}): hex=0x{x:0>2} PAK={d:4} -> NOT FOUND\n", .{type_names[i], i, offset, actual_idx});
            continue;
        };
        if (d.len < 10) {
            std.debug.print("  {s:>13} (type={d:2}): hex=0x{x:0>2} PAK={d:4} -> too small ({}b)\n", .{type_names[i], i, offset, actual_idx, d.len});
            continue;
        }
        const w: u32 = std.mem.readInt(u16, d[2..4], .little);
        const h: u32 = std.mem.readInt(u16, d[4..6], .little);
        std.debug.print("  {s:>13} (type={d:2}): hex=0x{x:0>2} PAK={d:4} -> {d}x{d} {}b\n", .{type_names[i], i, offset, actual_idx, w, h, d.len});
    }

    // Our current sprite_ids values (200-240)
    std.debug.print("\n=== Our current sprite_ids.Building (PAK indices 200-240) ===\n", .{});
    for (200..241) |i| {
        const d = pak.getFile(@intCast(i)) catch { continue; };
        if (d.len < 10) continue;
        const w: u32 = std.mem.readInt(u16, d[2..4], .little);
        const h: u32 = std.mem.readInt(u16, d[4..6], .little);
        std.debug.print("  [{d:3}] {d}x{d} {}b\n", .{i, w, h, d.len});
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
