const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const noise = core.noise;
    const perm = noise.Permutation.init(42);
    // Sample at integer coords (what generateTerrain does)
    std.debug.print("=== Integer coords (current bug) ===\n",.{});
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const v = noise.fbm_perlin2d(@floatFromInt(i), @floatFromInt(i*2), perm, 64, 64, 4);
        std.debug.print("  fbm({d}, {d}) = {d:.6}\n", .{ i, i*2, v });
    }
    // Sample at fractional coords
    std.debug.print("=== Fractional coords (correct) ===\n",.{});
    i = 0;
    while (i < 8) : (i += 1) {
        const fx: f64 = @as(f64, @floatFromInt(i)) * 10.0 / 64.0;
        const fy: f64 = @as(f64, @floatFromInt(i*2)) * 10.0 / 64.0;
        const v = noise.fbm_perlin2d(fx, fy, perm, 10, 10, 4);
        std.debug.print("  fbm({d:.4}, {d:.4}) = {d:.6}\n", .{ fx, fy, v });
    }
}
