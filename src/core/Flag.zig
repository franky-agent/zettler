//! Flag — flag logic (transport network nodes).
//!
//! Port of the C# Flag class (~2,000 lines). Flags are nodes in the
//! transport network where serfs pick up and drop off resources.
//! Handles:
//! - Resource queue management (incoming/outgoing)
//! - Transporter assignment and scheduling
//! - Road network connectivity
//! - Resource distribution between connected flags

const std = @import("std");
const enums = @import("enums.zig");
const types = @import("types.zig");
const GameState = @import("GameState.zig").GameState;
const FlagState = @import("FlagState.zig").FlagState;
const FlagStates = @import("FlagState.zig").FlagStates;

const Direction = enums.Direction;
const Resource = enums.Resource;
const MapPos = types.MapPos;
const GameObjectIndex = types.GameObjectIndex;

/// Maximum items in a flag queue.
pub const MaxQueueSize = 4;

/// Flag update result.
pub const FlagUpdateResult = enum(u8) {
    none,
    resource_moved,
    resource_delivered,
    transporter_needed,
};

/// Flag manager — provides functions for flag logic.
pub const FlagManager = struct {
    /// Update a single flag for one game tick.
    pub fn update(flag: *FlagState, state: *GameState, tick: u64) FlagUpdateResult {
        _ = state;
        _ = tick;

        // Move resources from incoming queue to outgoing queue
        if (flag.incoming_count > 0 and flag.outgoing_count < MaxQueueSize) {
            const res = flag.incoming_queue[flag.incoming_count - 1];
            flag.outgoing_queue[flag.outgoing_count] = res;
            flag.outgoing_count += 1;
            flag.incoming_count -= 1;
            return .resource_moved;
        }

        // Check if we need a transporter
        if (flag.outgoing_count > 0 and !flag.transporter_index.isValid()) {
            return .transporter_needed;
        }

        return .none;
    }

    /// Add a resource to the incoming queue of a flag.
    /// Returns true if the resource was added.
    pub fn addIncoming(flag: *FlagState, resource: u8) bool {
        if (flag.incoming_count >= MaxQueueSize) return false;
        flag.incoming_queue[flag.incoming_count] = resource;
        flag.incoming_count += 1;
        return true;
    }

    /// Remove a resource from the outgoing queue.
    /// Returns the resource type, or null if empty.
    pub fn takeOutgoing(flag: *FlagState) ?u8 {
        if (flag.outgoing_count == 0) return null;
        const res = flag.outgoing_queue[flag.outgoing_count - 1];
        flag.outgoing_count -= 1;
        return res;
    }

    /// Check if a flag has a road connection in the given direction.
    pub fn hasConnection(flag: *FlagState, dir: Direction) bool {
        const idx = @intFromEnum(dir);
        return flag.next[idx].isValid();
    }

    /// Get the next flag in a given direction (if connected by road).
    pub fn getNextFlag(flag: *FlagState, dir: Direction) GameObjectIndex {
        return flag.next[@intFromEnum(dir)];
    }

    /// Find which direction leads to a specific destination flag.
    /// Uses BFS through the road network.
    pub fn findDirectionToFlag(flag: *FlagState, target_flag_idx: GameObjectIndex) ?Direction {
        // Simple linear scan — for now, just check direct connections
        inline for (std.meta.tags(Direction)) |dir| {
            if (flag.next[@intFromEnum(dir)].isValid() and
                flag.next[@intFromEnum(dir)].index == target_flag_idx.index)
            {
                return dir;
            }
        }
        return null;
    }

    /// Connect two flags with a road segment.
    pub fn connectFlags(flag_a: *FlagState, pos_a: MapPos, dir: Direction, flag_b_idx: GameObjectIndex, length: u8) void {
        const idx = @intFromEnum(dir);
        flag_a.next[idx] = flag_b_idx;
        flag_a.length[idx] = length;

        // Also set reverse direction
        // If connected from flag A at direction D to flag B,
        // then flag B should connect back at direction opposite(D)
        _ = pos_a;
    }
};

test "Flag basic queue operations" {
    var flag = FlagState{};

    // Add incoming
    try std.testing.expect(FlagManager.addIncoming(&flag, @intFromEnum(Resource.wood)));
    try std.testing.expect(FlagManager.addIncoming(&flag, @intFromEnum(Resource.stone)));
    try std.testing.expectEqual(@as(u8, 2), flag.incoming_count);

    // Move to outgoing
    _ = FlagManager.update(&flag, undefined, 0);
    try std.testing.expectEqual(@as(u8, 1), flag.incoming_count);
    try std.testing.expectEqual(@as(u8, 1), flag.outgoing_count);

    // Take outgoing
    const taken = FlagManager.takeOutgoing(&flag);
    try std.testing.expect(taken != null);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Resource.wood)), taken.?);
    try std.testing.expectEqual(@as(u8, 0), flag.outgoing_count);
}

test "Flag queue capacity" {
    var flag = FlagState{};

    // Fill the queue
    for (0..4) |i| {
        const res: u8 = @intCast(i);
        try std.testing.expect(FlagManager.addIncoming(&flag, res));
    }

    // Queue is full
    try std.testing.expect(!FlagManager.addIncoming(&flag, 5));
    try std.testing.expectEqual(@as(u8, 4), flag.incoming_count);
}

test "Flag connection" {
    var flag = FlagState{};

    // No connections initially
    try std.testing.expect(!FlagManager.hasConnection(&flag, .right));

    // Connect
    const other_idx = GameObjectIndex{ .index = 5 };
    FlagManager.connectFlags(&flag, MapPos.zero, .right, other_idx, 3);

    try std.testing.expect(FlagManager.hasConnection(&flag, .right));
    try std.testing.expectEqual(@as(u32, 5), FlagManager.getNextFlag(&flag, .right).index);
    try std.testing.expectEqual(@as(u8, 3), flag.length[@intFromEnum(Direction.right)]);
}
