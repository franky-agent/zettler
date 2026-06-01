const std = @import("std");
const data = @import("data");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const path = "data/SPAE.PA";
    const c_path = try std.fmt.allocPrint(a, "{s}\x00", .{path});
    defer a.free(c_path);
    const fd = std.c.open(@ptrCast(c_path.ptr), .{});
    if (fd < 0) { std.debug.print("SPAE.PA not found\n", .{}); return; }
    defer _ = std.c.close(fd);
    const file_size = std.c.lseek(fd, 0, std.c.SEEK.END);
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
    const raw = try a.alloc(u8, @intCast(file_size));
    defer a.free(raw);
    _ = std.c.read(fd, raw.ptr, @intCast(file_size));

    var pak = data.PakFile.init(a, raw) catch |e| {
        std.debug.print("PAK error: {}\n", .{e});
        return;
    };
    defer pak.deinit();

    std.debug.print("File count: {}\n", .{pak.fileCount()});

    // Check construction-related sprite indices from freeserf:
    // 0x90=144 (cross), 0x91=145 (corner stone)
    // 0xaf=175 to 0xc1=193 (building frames)
    // 182-185 (flag/knight sprites, 4 frames)
    // 186-189, 190-193 (higher threat levels)
    const construction_indices = [_]u16{144, 145, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193};
    for (construction_indices) |idx| {
        if (idx >= pak.fileCount()) {
            std.debug.print("  [{}] PAST END\n", .{idx});
            continue;
        }
        const file_data = pak.getFile(idx) catch {
            std.debug.print("  [{}] ERROR\n", .{idx});
            continue;
        };
        if (file_data.len < 4) {
            std.debug.print("  [{}] too small ({}b)\n", .{idx, file_data.len});
            continue;
        }
        // BMP header: type (1=raw/solid, 2=RLE), w, h, dx, dy
        const sprite_type = file_data[0];
        const w: u16 = @bitCast(file_data[2..4].*);
        const h: u16 = @bitCast(file_data[4..6].*);
        const dx: i16 = @bitCast(file_data[6..8].*);
        const dy: i16 = @bitCast(file_data[8..10].*);
        std.debug.print("  [{}] type={} {}x{} dx={} dy={} {}b\n", .{idx, sprite_type, w, h, dx, dy, file_data.len});
    }
}
