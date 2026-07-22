//! Procedural Perlin noise with periodic (torus-safe) tiling.
//!
//! Produces deterministic, smoothly-interpolated noise that wraps seamlessly
//! at `(period_x, period_y)`. Used for terrain generation so the left edge
//! connects smoothly to the right edge and the top to the bottom — a
//! toroidal world with no visible seams.
//!
//! Implements classic 2D Perlin noise with a gradient table and quintic
//! interpolation for improved visual quality.

const std = @import("std");

/// 12 unit-gradient vectors used by classic Perlin noise.
const GRAD2: [12][2]f64 = .{
    .{ 1, 1 },  .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
    .{ 1, 0 },  .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
    .{ 1, 1 },  .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
};

/// Quintic fade curve: 6t^5 - 15t^4 + 10t^3.  Smoother than Hermite
/// (which has discontinuous 2nd derivatives at grid points).
fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Deterministic permutation table built from a 64-bit seed.
/// Uses a simple xorshift to shuffle indices 0..255.
pub const Permutation = struct {
    p: [512]u8,

    pub fn init(seed: u64) Permutation {
        var perm: Permutation = .{ .p = undefined };
        // Fill with 0..255
        for (&perm.p, 0..) |*v, i| {
            if (i < 256) {
                v.* = @intCast(i);
            }
            // upper half mirrors lower (standard Perlin trick)
        }

        // Fisher-Yates shuffle the lower half using the seed
        var s: u64 = seed;
        var i: usize = 255;
        while (i > 0) : (i -= 1) {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            const j: usize = @intCast(s % (@as(u64, i) + 1));
            const tmp = perm.p[i];
            perm.p[i] = perm.p[j];
            perm.p[j] = tmp;
        }
        // Mirror lower half into upper half (standard Perlin trick)
        for (0..256) |j| {
            perm.p[j + 256] = perm.p[j];
        }
        return perm;
    }

    /// Look up gradient dot-product for integer grid point (ix, iy).
    /// Uses the permutation table to select one of the 12 gradients,
    /// then dots it with the fractional offset (fx, fy).
    pub fn grad(self: Permutation, ix: u32, iy: u32, fx: f64, fy: f64) f64 {
        const h: usize = @intCast(self.p[@intCast((self.p[ix & 255] + iy) & 511)]);
        const g = GRAD2[h % 12];
        return g[0] * fx + g[1] * fy;
    }
};

/// Classic 2D Perlin noise at continuous coordinates `(x, y)`.
///
/// `perm` is the pre-built permutation table (seeded).
/// `period_x` and `period_y` are the repeat periods. At `x = period_x`
/// the noise value is identical to `x = 0`, making it tile seamlessly.
/// Set period to 0 for a non-periodic axis.
///
/// Returns a value in approximately [-1, 1].
pub fn perlin2d(x: f64, y: f64, perm: Permutation, period_x: u32, period_y: u32) f64 {
    // Determine unit grid cell containing (x, y)
    // Use i32 for floor to handle negative coordinates correctly.
    const fx: f64 = @floor(x);
    const fy: f64 = @floor(y);
    var xi: i32 = @intFromFloat(fx);
    var yi: i32 = @intFromFloat(fy);
    const xf = x - fx;
    const yf = y - fy;

    // Apply periodic wrapping to integer coordinates using modular arithmetic.
    // @mod on i32 always returns a non-negative result, which is what we need.
    if (period_x > 0) xi = @mod(xi, @as(i32, @intCast(period_x)));
    if (period_y > 0) yi = @mod(yi, @as(i32, @intCast(period_y)));

    // Convert to u32 for permutation table lookup (now guaranteed non-negative).
    const ux: u32 = @intCast(xi);
    const uy: u32 = @intCast(yi);

    // Neighbours — wrap at the period
    const ux1: u32 = if (period_x > 0) (ux + 1) % period_x else ux + 1;
    const uy1: u32 = if (period_y > 0) (uy + 1) % period_y else uy + 1;

    // Fade curves for interpolation
    const u = fade(xf);
    const v = fade(yf);

    // Gradients at the four corners
    const n00 = perm.grad(ux, uy, xf, yf);
    const n10 = perm.grad(ux1, uy, xf - 1.0, yf);
    const n01 = perm.grad(ux, uy1, xf, yf - 1.0);
    const n11 = perm.grad(ux1, uy1, xf - 1.0, yf - 1.0);

    // Bilinear interpolation
    const nx0 = n00 + u * (n10 - n00);
    const nx1 = n01 + u * (n11 - n01);
    return nx0 + v * (nx1 - nx0);
}

/// Multi-octave (fractal Brownian motion) Perlin noise.
///
/// Layers `octaves` passes of `perlin2d` at increasing frequency and
/// decreasing amplitude (persistence). Produces natural-looking terrain
/// with large-scale features and fine detail.
///
/// Returns a value in approximately [-1, 1].
pub fn fbm_perlin2d(x: f64, y: f64, perm: Permutation, period_x: u32, period_y: u32, octaves: u32) f64 {
    var value: f64 = 0.0;
    var amplitude: f64 = 1.0;
    var frequency: f64 = 1.0;
    var max_amp: f64 = 0.0;

    for (0..octaves) |_| {
        value += amplitude * perlin2d(x * frequency, y * frequency, perm, period_x, period_y);
        max_amp += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }

    return value / max_amp;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "Perlin noise periodicity — wraps at period" {
    const perm = Permutation.init(42);
    const period_x: u32 = 64;
    const period_y: u32 = 64;
    const v00 = perlin2d(0, 0, perm, period_x, period_y);
    const v_px = perlin2d(@floatFromInt(period_x), 0, perm, period_x, period_y);
    const v_py = perlin2d(0, @floatFromInt(period_y), perm, period_x, period_y);
    try std.testing.expectApproxEqAbs(v00, v_px, 0.0001);
    try std.testing.expectApproxEqAbs(v00, v_py, 0.0001);
}

test "Perlin noise smoothness — nearby points are close" {
    const perm = Permutation.init(42);
    const period_x: u32 = 64;
    const period_y: u32 = 64;
    const v = perlin2d(10.0, 10.0, perm, period_x, period_y);
    const v2 = perlin2d(10.1, 10.1, perm, period_x, period_y);
    try std.testing.expect(@abs(v - v2) < 0.3);
}

test "Perlin noise range — produces values in [-1, 1] range" {
    const perm = Permutation.init(42);
    const period_x: u32 = 64;
    const period_y: u32 = 64;
    var lo: f64 = 100.0;
    var hi: f64 = -100.0;
    for (0..200) |i| {
        const x: f64 = @as(f64, @floatFromInt(i)) * 0.3;
        const v = perlin2d(x, x * 0.7, perm, period_x, period_y);
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try std.testing.expect(lo > -1.5);
    try std.testing.expect(hi < 1.5);
}

test "FBM periodicity — wraps at period" {
    const perm = Permutation.init(42);
    const period_x: u32 = 64;
    const period_y: u32 = 64;
    const v00 = fbm_perlin2d(0, 0, perm, period_x, period_y, 4);
    const v_px = fbm_perlin2d(@floatFromInt(period_x), 0, perm, period_x, period_y, 4);
    try std.testing.expectApproxEqAbs(v00, v_px, 0.01);
}

test "FBM produces varied values" {
    const perm = Permutation.init(42);
    const period_x: u32 = 64;
    const period_y: u32 = 64;
    var lo: f64 = 1.0;
    var hi: f64 = -1.0;
    for (0..100) |i| {
        const x: f64 = @floatFromInt(i);
        const v = fbm_perlin2d(x, x * 0.7, perm, period_x, period_y, 4);
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try std.testing.expect(lo < -0.2);
    try std.testing.expect(hi > 0.2);
}