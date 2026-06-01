//! Core enums for Freeserf
//!
//! These enums are used throughout the game engine and correspond
//! to the original Settlers (1993) game mechanics.

const std = @import("std");

/// Map directions in the original Settlers / freeserf sheared-grid model.
///
///    A ______ B
///     /\    /
///    /  \  /
/// C /____\/ D
///
/// RIGHT(0):      A to B  (col+1)
/// DOWN_RIGHT(1):  A to D  (col+1, row+1)
/// DOWN(2):        A to C  (row+1)
/// LEFT(3):        D to C  (col-1)
/// UP_LEFT(4):     D to A  (col-1, row-1)
/// UP(5):          D to B  (row-1)
///
/// This is NOT an offset-row hex grid! The map is a regular square grid
/// (col, row) that gets sheared into diamond/hex appearance via the
/// isometric rendering projection: screen_x = col*32 - row*16.
pub const Direction = enum(u3) {
    right = 0,
    down_right = 1,
    down = 2,
    left = 3,
    up_left = 4,
    up = 5,

    pub const count = 6;

    /// Return the opposite direction.
    pub fn opposite(self: Direction) Direction {
        return @as(Direction, @enumFromInt((@intFromEnum(self) + 3) % 6));
    }

    /// Return the direction turned 60 degrees clockwise.
    pub fn clockwise(self: Direction) Direction {
        return @as(Direction, @enumFromInt((@intFromEnum(self) + 1) % 6));
    }

    /// Return the direction turned 60 degrees counter-clockwise.
    pub fn counterClockwise(self: Direction) Direction {
        return @as(Direction, @enumFromInt((@intFromEnum(self) + 5) % 6));
    }
};

/// Resource types available in the game.
pub const Resource = enum(u8) {
    // Raw materials
    fish = 0,
    grain = 1,
    flour = 2,
    bread = 3,
    meat = 4,
    fruit = 5,
    beer = 6,
    wine = 7,
    gold = 8,
    iron_ore = 9,
    iron = 10,
    coal = 11,
    stone = 12,
    wood = 13,
    planks = 14,
    // Tools
    shovel = 15,
    hammer = 16,
    saw = 17,
    scythe = 18,
    axe = 19,
    pick = 20,
    boat = 21,
    // Special
    sword = 22,
    shield = 23,
    // Non-material resources
    serf = 24,
    knight = 25,
    // Count
    count = 26,

    /// The maximum number of different resource types.
    pub const max_count = 26;

    /// Convert to a display-friendly name.
    pub fn name(self: Resource) []const u8 {
        return switch (self) {
            .fish => "Fish",
            .grain => "Grain",
            .flour => "Flour",
            .bread => "Bread",
            .meat => "Meat",
            .fruit => "Fruit",
            .beer => "Beer",
            .wine => "Wine",
            .gold => "Gold",
            .iron_ore => "Iron Ore",
            .iron => "Iron",
            .coal => "Coal",
            .stone => "Stone",
            .wood => "Wood",
            .planks => "Planks",
            .shovel => "Shovel",
            .hammer => "Hammer",
            .saw => "Saw",
            .scythe => "Scythe",
            .axe => "Axe",
            .pick => "Pick",
            .boat => "Boat",
            .sword => "Sword",
            .shield => "Shield",
            .serf => "Serf",
            .knight => "Knight",
        };
    }

    /// Whether this resource is a tool.
    pub fn isTool(self: Resource) bool {
        return @intFromEnum(self) >= 15 and @intFromEnum(self) <= 21;
    }

    /// Whether this resource is a raw material.
    pub fn isRawMaterial(self: Resource) bool {
        return @intFromEnum(self) <= 14;
    }

    /// Whether this resource is a weapon/armor.
    pub fn isEquipment(self: Resource) bool {
        return self == .sword or self == .shield;
    }
};

/// Building types in the game (24 types).
pub const Building = enum(u8) {
    none = 0,
    stonecutter = 1,
    lumberjack = 2,
    boatbuilder = 3,
    sawmill = 4,
    forester = 5,
    stock = 6,
    granite_mine = 7,
    coal_mine = 8,
    iron_mine = 9,
    gold_mine = 10,
    iron_smelter = 11,
    gold_smelter = 12,
    armory = 13,
    toolmaker = 14,
    bakery = 15,
    mill = 16,
    slaughterhouse = 17,
    pig_farm = 18,
    brewery = 19,
    winery = 20,
    farm = 21,
    fisher = 22,
    tower = 23,
    fortress = 24,


    pub const count = 25;

    /// Whether this building produces resources.
    pub fn isProducer(self: Building) bool {
        return switch (self) {
            .none, .stock, .tower, .fortress => false,
            else => true,
        };
    }

    /// Whether this building is a mine (requires mountain terrain).
    pub fn isMine(self: Building) bool {
        return switch (self) {
            .granite_mine, .coal_mine, .iron_mine, .gold_mine => true,
            else => false,
        };
    }

    /// Whether this building is a military building.
    pub fn isMilitary(self: Building) bool {
        return switch (self) {
            .tower, .fortress => true,
            else => false,
        };
    }

    /// Whether this building requires a flag for resource input/output.
    pub fn needsFlag(self: Building) bool {
        return switch (self) {
            .none, .stock => false,
            .tower, .fortress => false,
            else => true,
        };
    }

    pub fn name(self: Building) []const u8 {
        return switch (self) {
            .none => "None",
            .stonecutter => "Stonecutter",
            .lumberjack => "Lumberjack",
            .boatbuilder => "Boatbuilder",
            .sawmill => "Sawmill",
            .forester => "Forester",
            .stock => "Stock",
            .granite_mine => "Granite Mine",
            .coal_mine => "Coal Mine",
            .iron_mine => "Iron Mine",
            .gold_mine => "Gold Mine",
            .iron_smelter => "Iron Smelter",
            .gold_smelter => "Gold Smelter",
            .armory => "Armory",
            .toolmaker => "Toolmaker",
            .bakery => "Bakery",
            .mill => "Mill",
            .slaughterhouse => "Slaughterhouse",
            .pig_farm => "Pig Farm",
            .brewery => "Brewery",
            .winery => "Winery",
            .farm => "Farm",
            .fisher => "Fisher",
            .tower => "Tower",
            .fortress => "Fortress",
        };
    }
};

/// Serf types (professions).
pub const SerfType = enum(u8) {
    // Basic
    none = 0,
    serf = 1,         // basic transporter
    builder = 2,
    // Raw material
    stonecutter = 3,
    lumberjack = 4,
    fisher = 5,
    farmer = 6,
    forester = 7,
    miner = 8,        // generic miner (granite, coal, iron, gold)
    pig_farmer = 9,
    // Processing
    boatbuilder = 10,
    smelter = 11,
    armor_smith = 12,
    toolmaker = 13,
    baker = 14,
    miller = 15,
    butcher = 16,
    brewer = 17,
    winemaker = 18,
    sawmiller = 19,
    // Transport
    transporter = 20, // assigned to a flag route
    // Military
    knight_0 = 21,    // lowest rank
    knight_1 = 22,
    knight_2 = 23,
    knight_3 = 24,
    knight_4 = 25,
    knight_5 = 26,    // highest rank
    // Special
    geologist = 27,
    generic = 28,     // generic serf (can be assigned)
    // Count
    count = 29,

    pub fn isKnight(self: SerfType) bool {
        return @intFromEnum(self) >= 21 and @intFromEnum(self) <= 26;
    }

    pub fn isTransporter(self: SerfType) bool {
        return self == .transporter;
    }

    pub fn name(self: SerfType) []const u8 {
        return switch (self) {
            .none => "None",
            .serf => "Serf",
            .builder => "Builder",
            .stonecutter => "Stonecutter",
            .lumberjack => "Lumberjack",
            .fisher => "Fisher",
            .farmer => "Farmer",
            .forester => "Forester",
            .miner => "Miner",
            .pig_farmer => "Pig Farmer",
            .boatbuilder => "Boatbuilder",
            .smelter => "Smelter",
            .armor_smith => "Armor Smith",
            .toolmaker => "Toolmaker",
            .baker => "Baker",
            .miller => "Miller",
            .butcher => "Butcher",
            .brewer => "Brewer",
            .winemaker => "Winemaker",
            .sawmiller => "Sawmiller",
            .transporter => "Transporter",
            .knight_0 => "Knight",
            .knight_1 => "Senior Knight",
            .knight_2 => "Master Knight",
            .knight_3 => "Hero",
            .knight_4 => "Champion",
            .knight_5 => "Legendary Knight",
            .geologist => "Geologist",
            .generic => "Generic",
        };
    }
};

/// The main states a serf can be in (~80 states).
/// This is a tagged union for type safety — each state variant
/// carries the data relevant to that state.
pub const SerfState = union(enum(u16)) {
    // Idle / waiting
    idle_in_stock,
    waiting_at_flag,
    wandering,
    // Movement
    walking_on_road,
    walking_on_land,
    entering_building,
    leaving_building,
    leaving_building_2,
    // Transport
    transporting,
    transporting_on_road,
    // Building construction
    building_construction,
    building_construction_2,
    // Resource gathering
    lumberjack_felling,
    lumberjack_felling_2,
    lumberjack_felling_3,
    fisher_fishing,
    fisher_fishing_2,
    farmer_planting,
    farmer_harvesting,
    forester_planting,
    forester_cutting,
    miner_mining,
    miner_mining_2,
    miner_mining_3,
    stonecutter_mining,
    stonecutter_mining_2,
    pig_farmer_feeding,
    pig_farmer_slaughtering,
    // Processing
    miller_grinding,
    baker_baking,
    butcher_butchering,
    brewer_brewing,
    winemaker_making_wine,
    smelter_smelting,
    armor_smith_forging,
    toolmaker_making_tools,
    sawmiller_sawing,
    boatbuilder_building,
    // Military
    defending,
    defending_2,
    attacking,
    attacking_2,
    fighting,
    fighting_2,
    fleeing,
    fleeing_2,
    going_to_enemy,
    going_to_enemy_2,
    // Knight promotion
    knight_promotion,
    knight_promotion_2,
    // Geologist
    geologist_searching,
    geologist_searching_2,
    geologist_found,
    // Transport / delivery states
    delivering_to_building,
    delivering_to_building_2,
    delivering_to_flag,
    delivering_from_building,
    delivering_from_building_2,
    picking_up_from_flag,
    delivering_to_stock,
    picking_up_from_stock,
    // Misc
    sleeping,
    sleeping_2,
    waiting_for_guide,
    following_guide,
    lost,
    drowning,
    drowning_2,
    burning,
    // Builder states
    builder_walking,
    builder_constructing,
    builder_constructing_2,
    // Path search
    searching_for_path,

    /// Number of serf state variants.
    pub const count: u16 = @typeInfo(@This()).Union.fields.len;
};
