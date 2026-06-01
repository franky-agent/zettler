const std = @import("std");
const PakFile = @import("src/data/pak.zig").PakFile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw = try std.fs.cwd().readFileAlloc(allocator, "data/SPAE.PA", 10 * 1024 * 1024);
    defer allocator.free(raw);
    var pak = try PakFile.init(allocator, raw);
    defer pak.deinit();
    std.debug.print("File count: {}\n", .{pak.fileCount()});

    const indices = [_]u32{ 0, 90, 91, 100, 144, 145, 175, 182, 183, 184, 185, 186, 198, 199, 200, 220, 223, 224, 225, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 299, 300, 400, 500, 1000, 1364, 1372, 2000 };
    for (indices) |idx| {
        if (idx < pak.fileCount()) {
            const data = pak.getFile(idx) catch {
                std.debug.print("  index {}: ERROR reading\n", .{idx});
                continue;
            };
            const h = if (data.len >= 4) data[0..4] else &[_]u8{0,0,0,0};
            std.debug.print("  index {}: {} bytes, [{x:0>2} {x:0>2} {x:0>2} {x:0>2}]\n", .{idx, data.len, h[0], h[1], h[2], h[3]});
        } else {
            std.debug.print("  index {}: PAST END\n", .{idx});
        }
    }
}
