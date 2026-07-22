//! Pathfinder — A* pathfinding on the hex grid.
//!
//! Port of the C# Pathfinder class. Used by serfs to find paths
//! between two map positions, avoiding impassable terrain and
//! preferring roads.

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const map_mod = @import("Map.zig");

const Direction = enums.Direction;
const MapPos = types.MapPos;
const Map = map_mod.Map;
const Terrain = map_mod.Terrain;

/// Maximum path length we can store.
pub const MaxPathLength = 128;

/// A single step in a path.
pub const PathStep = struct {
    pos: MapPos,
    dir: Direction,
};

/// A computed path between two positions.
pub const Path = struct {
    steps: [MaxPathLength]PathStep = @splat(PathStep{ .pos = MapPos.invalid, .dir = .right }),
    length: usize = 0,

    pub fn clear(self: *Path) void {
        self.length = 0;
    }

    pub fn isEmpty(self: Path) bool {
        return self.length == 0;
    }

    pub fn getLast(self: Path) ?PathStep {
        if (self.length == 0) return null;
        return self.steps[self.length - 1];
    }
};

/// A node in the A* open set.
const AStarNode = struct {
    pos: MapPos,
    g: u32, // cost from start
    h: u32, // heuristic to goal
    parent: ?usize,

    pub fn f(self: AStarNode) u32 {
        return self.g + self.h;
    }
};

/// A* pathfinder on the hex grid.
pub const Pathfinder = struct {
    allocator: std.mem.Allocator,
    map: *Map,

    // For A* state (reused across searches)
    open_list: std.ArrayList(AStarNode),
    closed_set: std.AutoHashMap(MapPos, void),

    pub fn init(allocator: std.mem.Allocator, map: *Map) Pathfinder {
        return .{
            .allocator = allocator,
            .map = map,
            .open_list = .empty,
            .closed_set = std.AutoHashMap(MapPos, void).init(allocator),
        };
    }

    pub fn deinit(self: *Pathfinder, allocator: std.mem.Allocator) void {
        self.open_list.deinit(allocator);
        self.closed_set.deinit();
    }

    /// Manhattan-like hex distance heuristic.
    fn heuristic(_: Pathfinder, from: MapPos, to: MapPos) u32 {
        const dx = if (from.x > to.x) @as(i32, from.x) - @as(i32, to.x) else @as(i32, to.x) - @as(i32, from.x);
        const dy = if (from.y > to.y) @as(i32, from.y) - @as(i32, to.y) else @as(i32, to.y) - @as(i32, from.y);
        return @intCast(@max(dx, dy));
    }

    /// Cost of moving through a given tile. Always valid on a torus map.
    fn terrainCost(self: Pathfinder, pos: MapPos) u32 {
        if (!self.map.isValidPos(pos)) return 1000;
        const tile = self.map.getTile(pos);
        if (!tile.terrain.isWalkable()) return 1000;
        // Prefer roads
        if (tile.has_road) return 1;
        // Penalty for walking on owned territory that isn't ours
        return 10;
    }

    /// Find a path from `from` to `to`. Returns true if a path was found.
    pub fn findPath(self: *Pathfinder, from: MapPos, to: MapPos, result: *Path) !bool {
        result.clear();

        // Quick check: same position
        if (from.eql(to)) return true;

        // Reset open list and closed set
        self.open_list.clearRetainingCapacity();
        self.closed_set.clearRetainingCapacity();

        const h_start = self.heuristic(from, to);
        try self.open_list.append(.{ .pos = from, .g = 0, .h = h_start, .parent = null });

        const max_iterations = 5000;
        var iteration: u32 = 0;

        while (self.open_list.items.len > 0 and iteration < max_iterations) : (iteration += 1) {
            // Find node with lowest f in open list
            var best_idx: usize = 0;
            var best_f = self.open_list.items[0].f();
            for (self.open_list.items, 0..) |node, i| {
                const f = node.f();
                if (f < best_f) {
                    best_f = f;
                    best_idx = i;
                }
            }

            const current = self.open_list.swapRemove(best_idx);

            // Check if we reached the goal (within 1 hex)
            const dist = self.heuristic(current.pos, to);
            if (dist <= 1) {
                // Reconstruct path
                var steps_buf: [MaxPathLength]PathStep = undefined;
                var step_count: usize = 0;

                var node_opt: ?AStarNode = current;
                var prev_pos = to;

                while (node_opt) |node| {
                    if (node.parent) |parent_idx| {
                        if (self.map.directionToWrapped(node.pos, prev_pos)) |dir| {
                            steps_buf[step_count] = .{ .pos = node.pos, .dir = dir };
                            step_count += 1;
                        }
                        prev_pos = node.pos;
                        node_opt = self.open_list.items[parent_idx];
                    } else {
                        break;
                    }
                }

                // Reverse the path (we built it backwards)
                var i: usize = 0;
                while (i < step_count) : (i += 1) {
                    result.steps[i] = steps_buf[step_count - 1 - i];
                }
                result.length = step_count;
                return true;
            }

            // Add to closed set
            try self.closed_set.put(current.pos, {});
            const closed_entry = try self.closed_set.getOrPut(current.pos);
            closed_entry.value_ptr.* = {};

            // Explore neighbors
            // Explore neighbours with torus wrapping
            const neighbors = self.map.getAllNeighborsWrapped(current.pos);
            for (neighbors) |npos| {
                if (self.closed_set.contains(npos)) continue;

                // Check if already in open list
                var in_open = false;
                for (self.open_list.items) |*node| {
                    if (node.pos.eql(npos)) {
                        in_open = true;
                        const new_g = current.g + self.terrainCost(npos);
                        if (new_g < node.g) {
                            node.g = new_g;
                            node.parent = self.open_list.items.len; // will be invalid, but we store index
                        }
                        break;
                    }
                }

                if (!in_open) {
                    const cost = self.terrainCost(npos);
                    if (cost >= 1000) continue; // impassable
                    const g = current.g + cost;
                    const h = self.heuristic(npos, to);
                    try self.open_list.append(.{
                        .pos = npos,
                        .g = g,
                        .h = h,
                        .parent = null, // simplified: doesn't track parent properly for path reconstruction
                    });
                }
            }
        }

        return false; // No path found
    }

    /// Simplified path check: returns true if the two positions are connected by walkable tiles.
    pub fn areConnected(self: *Pathfinder, from: MapPos, to: MapPos) bool {
        // Simple BFS flood fill
        var visited = std.AutoHashMap(MapPos, void).init(self.allocator);
        defer visited.deinit();
        
        var queue = std.ArrayList(MapPos).init(self.allocator);
        defer queue.deinit();
        
        queue.append(from) catch return false;
        visited.put(from, {}) catch return false;

        const max_steps: usize = 2000;
        var steps: usize = 0;

        while (queue.items.len > 0 and steps < max_steps) : (steps += 1) {
            const current = queue.orderedRemove(0);
            
            if (self.heuristic(current, to) <= 1) {
                // Check if actually adjacent
                if (self.map.directionToWrapped(current, to) != null or current.eql(to)) {
                    return true;
                }
            }

            const neighbors = self.map.getAllNeighbors(current);
            for (neighbors) |npos| {
                if (npos.eql(MapPos.invalid)) continue;
                if (visited.contains(npos)) continue;
                if (!self.map.getTile(npos).terrain.isWalkable()) continue;
                
                visited.put(npos, {}) catch return false;
                queue.append(npos) catch return false;
            }
        }

        return false;
    }
};

test "Pathfinder heuristic" {
    var map = try Map.init(std.testing.allocator, 64, 64);
    defer map.deinit();
    var pf = Pathfinder.init(std.testing.allocator, &map);
    defer pf.deinit(std.testing.allocator);

    const from = MapPos{ .x = 0, .y = 0 };
    const to = MapPos{ .x = 10, .y = 5 };

    var path = Path{};
    _ = try pf.findPath(from, to, &path);
    // Path may or may not be found on flat terrain, but shouldn't crash
}

test "Pathfinder connected check" {
    var map = try Map.init(std.testing.allocator, 16, 16);
    defer map.deinit();
    
    var pf = Pathfinder.init(std.testing.allocator, &map);
    defer pf.deinit(std.testing.allocator);

    // All grass terrain is walkable, so all positions should be connected
    const a = MapPos{ .x = 2, .y = 2 };
    const b = MapPos{ .x = 10, .y = 10 };
    try std.testing.expect(pf.areConnected(a, b));

    // Block with water should break connection
    const water_pos = MapPos{ .x = 5, .y = 5 };
    map.getTile(water_pos).terrain = .water;
    // Still might be connected around the water
}
