//! Sprite IDs — known sprite indices in the SPAE.PA archive.
//!
//! These IDs are based on the original C++ freeserf source code.
//! Building sprites live in the AssetMapObject asset which starts at PAK
//! index 1250. The map_building_sprite[] table in interface.h maps building
//! TYPE to a hex offset within AssetMapObject:
//!
//!   Actual PAK index = 1250 + hex_offset
//!
//! Verified against /tmp/freeserf/src/interface.h:33-38 and
//! /tmp/freeserf/src/data-source-dos.cc:76.

/// AssetMapObject base index in SPAE.PA.
pub const MAP_OBJECT_BASE: u16 = 1250;

/// Terrain map tiles (0-199).
/// These are sprite IDs in the game_object asset (base 321) and map_ground
/// asset (base 260), not direct PAK indices.
pub const Terrain = struct {
    pub const first: u16 = 0;
    pub const grass_0: u16 = 0;
    pub const grass_1: u16 = 1;
    pub const grass_2: u16 = 2;
    pub const water_0: u16 = 10;
    pub const water_1: u16 = 11;
    pub const mountain_0: u16 = 20;
    pub const mountain_1: u16 = 21;
    pub const sand: u16 = 30;
    pub const snow: u16 = 35;
    pub const swamp: u16 = 40;
    pub const lava: u16 = 45;
    pub const last: u16 = 199;
};

/// Building sprite IDs — offsets within AssetMapObject (base PAK index 1250).
///
/// These hex offsets come from /tmp/freeserf/src/interface.h:33-38.
/// The C++ map_building_sprite[] array maps building TYPE (by C++ enum
/// position) to a hex offset within AssetMapObject.
///
/// Actual PAK index = MAP_OBJECT_BASE + hex_offset.
///
/// Note: the C++ and Zig building enums have completely different ordering.
/// The mapping below matches by building NAME, not by enum position.
pub const Building = struct {
    pub const first: u16 = MAP_OBJECT_BASE + 0x98;  // fortress (smallest offset)
    pub const last: u16 = MAP_OBJECT_BASE + 0xc0;   // stock (largest offset)

    // Hex offsets from C++ map_building_sprite[], by C++ enum type:
    //   None=0 (0), Fisher=1 (0xa7), Lumberjack=2 (0xa8),
    //   Boatbuilder=3 (0xae), Stonecutter=4 (0xa9),
    //   StoneMine=5 (0xa3), CoalMine=6 (0xa4), IronMine=7 (0xa5),
    //   GoldMine=8 (0xa6), Forester=9 (0xaa), Stock=10 (0xc0),
    //   Hut=11 (0xab), Farm=12 (0x9a), Butcher=13 (0x9c),
    //   PigFarm=14 (0x9b), Mill=15 (0xbc), Baker=16 (0xa2),
    //   Sawmill=17 (0xa0), SteelSmelter=18 (0xa1),
    //   ToolMaker=19 (0x99), WeaponSmith=20 (0x9d),
    //   Tower=21 (0x9e), Fortress=22 (0x98),
    //   GoldSmelter=23 (0x9f), Castle=24 (0xb2)

    pub const fisher: u16 = MAP_OBJECT_BASE + 0xa7;  // PAK 1417
    pub const lumberjack: u16 = MAP_OBJECT_BASE + 0xa8;  // PAK 1418
    pub const boatbuilder: u16 = MAP_OBJECT_BASE + 0xae;  // PAK 1424
    pub const stonecutter: u16 = MAP_OBJECT_BASE + 0xa9;  // PAK 1419
    pub const granite_mine: u16 = MAP_OBJECT_BASE + 0xa3;  // PAK 1413 (StoneMine)
    pub const coal_mine: u16 = MAP_OBJECT_BASE + 0xa4;  // PAK 1414
    pub const iron_mine: u16 = MAP_OBJECT_BASE + 0xa5;  // PAK 1415
    pub const gold_mine: u16 = MAP_OBJECT_BASE + 0xa6;  // PAK 1416
    pub const forester: u16 = MAP_OBJECT_BASE + 0xaa;  // PAK 1420
    pub const stock: u16 = MAP_OBJECT_BASE + 0xc0;  // PAK 1442
    pub const farm: u16 = MAP_OBJECT_BASE + 0x9a;  // PAK 1404
    pub const slaughterhouse: u16 = MAP_OBJECT_BASE + 0x9c;  // PAK 1406 (Butcher)
    pub const pig_farm: u16 = MAP_OBJECT_BASE + 0x9b;  // PAK 1405
    pub const mill: u16 = MAP_OBJECT_BASE + 0xbc;  // PAK 1438
    pub const bakery: u16 = MAP_OBJECT_BASE + 0xa2;  // PAK 1412 (Baker)
    pub const sawmill: u16 = MAP_OBJECT_BASE + 0xa0;  // PAK 1410
    pub const iron_smelter: u16 = MAP_OBJECT_BASE + 0xa1;  // PAK 1411 (SteelSmelter)
    pub const toolmaker: u16 = MAP_OBJECT_BASE + 0x99;  // PAK 1403 (ToolMaker)
    pub const armory: u16 = MAP_OBJECT_BASE + 0x9d;  // PAK 1407 (WeaponSmith)
    pub const tower: u16 = MAP_OBJECT_BASE + 0x9e;  // PAK 1408
    pub const fortress: u16 = MAP_OBJECT_BASE + 0x98;  // PAK 1402
    pub const gold_smelter: u16 = MAP_OBJECT_BASE + 0x9f;  // PAK 1409 (GoldSmelter)

    // Brewery and winery are not in the C++ freeserf building enum.
    // They may have different sprite IDs in the C#-derived enum.
    // For now, they return null (colored fallback).

    /// Get the sprite ID for a game Building enum.
    pub fn fromGameBuilding(b: core.Building) ?u16 {
        return switch (b) {
            .lumberjack => lumberjack,
            .stonecutter => stonecutter,
            .fisher => fisher,
            .forester => forester,
            .sawmill => sawmill,
            .boatbuilder => boatbuilder,
            .farm => farm,
            .mill => mill,
            .bakery => bakery,
            .slaughterhouse => slaughterhouse,
            .pig_farm => pig_farm,
            .brewery => null,       // no C++ equivalent
            .winery => null,         // no C++ equivalent
            .coal_mine => coal_mine,
            .iron_mine => iron_mine,
            .gold_mine => gold_mine,
            .granite_mine => granite_mine,
            .iron_smelter => iron_smelter,
            .gold_smelter => gold_smelter,
            .armory => armory,
            .toolmaker => toolmaker,
            .stock => stock,
            .tower => tower,
            .fortress => fortress,
            else => null,
        };
    }
};

/// Serf sprites (300-499).
pub const Serf = struct {
    pub const first: u16 = 300;
    pub const walk_base: u16 = 300;
    pub const last: u16 = 500;
};

/// UI elements (500+).
pub const UI = struct {
    pub const first: u16 = 500;
    pub const panel_bg: u16 = 500;
    pub const button: u16 = 510;
    pub const resource_icon_base: u16 = 600;
    pub const last: u16 = 1000;
};

/// Font glyphs (typically 1000+).
pub const Font = struct {
    pub const first: u16 = 1000;
    pub const char_base: u16 = 1000;
    pub const last: u16 = 1128;
};

const core = @import("core");
