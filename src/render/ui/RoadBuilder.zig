//! RoadBuilder — handles road construction between flags.
//!
//! The player clicks a flag, then a second flag; a road is built between them.
//! Roads enable serf transport of resources along the flag network.
//!
//! Path-finding here is a simple greedy walk toward the target (good enough for
//! short flag-to-flag roads on open terrain). The project's A* Pathfinder has a
//! known-broken path reconstruction, so we deliberately don't use it here.

const std = @import("std");
const core = @import("core");

const Map = core.map.Map;
const Direction = core.Direction;
const MapPos = core.types.MapPos;

/// Greedy chebyshev-style distance, matching Pathfinder.heuristic.
fn hexDist(a: MapPos, b: MapPos) i32 {
    const dx = @as(i32, a.x) - @as(i32, b.x);
    const dy = @as(i32, a.y) - @as(i32, b.y);
    return @intCast(@max(@abs(dx), @abs(dy)));
}

/// Pick the step direction from `from` that gets closest to `to`, skipping
/// water and buildings. Returns the direction that lands on `to` immediately if
/// adjacent, else the best distance-reducing move, or null if all are blocked.
fn bestStep(from: MapPos, to: MapPos, map: *Map) ?Direction {
    var best_dir: ?Direction = null;
    var best_d: i32 = std.math.maxInt(i32);
    inline for (std.meta.tags(Direction)) |d| {
        const np = from.move(d);
        if (map.isValidPos(np)) {
            if (np.eql(to)) return d;
            const t = map.getTile(np);
            if (!t.has_building and !t.terrain.isWater()) {
                const dd = hexDist(np, to);
                if (dd < best_d) {
                    best_d = dd;
                    best_dir = d;
                }
            }
        }
    }
    return best_dir;
}

/// Road building tool state.
pub const RoadBuilder = struct {
    /// Whether road building mode is active.
    active: bool = false,
    /// The first flag selected (start of road).
    start_flag_pos: MapPos = .{ .x = 0, .y = 0 },
    /// Whether the first flag has been selected.
    has_start: bool = false,
    /// The current cursor position (for preview).
    cursor_pos: MapPos = .{ .x = 0, .y = 0 },
    /// The calculated path (direction steps) from start to cursor.
    path: [128]u8 = undefined,
    path_len: usize = 0,
    /// Whether a valid road path exists.
    has_path: bool = false,

    pub fn init() RoadBuilder {
        return RoadBuilder{};
    }

    pub fn activate(self: *RoadBuilder) void {
        self.active = true;
        self.has_start = false;
        self.path_len = 0;
        self.has_path = false;
    }

    pub fn deactivate(self: *RoadBuilder) void {
        self.active = false;
        self.has_start = false;
        self.path_len = 0;
        self.has_path = false;
    }

    /// Try to start a road from a flag at the given map position.
    /// Returns true if a flag was found there.
    pub fn tryStartAt(self: *RoadBuilder, pos: MapPos, map: *Map) bool {
        if (!self.active) return false;
        if (!map.getTile(pos).has_flag) return false;
        self.start_flag_pos = pos;
        self.has_start = true;
        self.path_len = 0;
        self.has_path = false;
        return true;
    }

    /// Update the path preview from the start flag to the cursor tile.
    pub fn updatePath(self: *RoadBuilder, cursor_pos: MapPos, map: *Map) void {
        if (!self.active or !self.has_start) return;
        self.cursor_pos = cursor_pos;
        self.path_len = 0;
        self.has_path = false;
        if (cursor_pos.eql(self.start_flag_pos)) return;

        var p = self.start_flag_pos;
        var steps: usize = 0;
        while (steps < self.path.len) {
            if (p.eql(cursor_pos)) {
                self.path_len = steps;
                self.has_path = steps > 0;
                return;
            }
            const d = bestStep(p, cursor_pos, map) orelse return;
            self.path[steps] = @intFromEnum(d);
            p = p.move(d);
            steps += 1;
        }
    }

    /// Cancel road building.
    pub fn cancel(self: *RoadBuilder) void {
        self.deactivate();
    }
};
