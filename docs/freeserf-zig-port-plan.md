# Freeserf.net → Zig Port Plan

**Target platforms**: macOS (x86_64 + aarch64), Linux (x86_64 + aarch64)  
**Target Zig version**: 0.17-dev (master)  
**Source codebase**: [freeserf.net](https://github.com/pyrdacor/freeserf.net) by Robert Schneckenhaus  
**Original game**: The Settlers (1993) by Blue Byte Software  
**License**: GPL v3

---

## Table of Contents

1. [Project Scope](#1-project-scope)
2. [External Dependencies & Zig Replacements](#2-external-dependencies--zig-replacements)
3. [The Serialization Challenge](#3-the-serialization-challenge)
4. [Porting Strategy — By Module](#4-porting-strategy--by-module)
5. [Estimated Totals](#5-estimated-totals)
6. [Key Zig-Specific Design Decisions](#6-key-zig-specific-design-decisions)
7. [Module Layout](#7-module-layout)
8. [Risk Areas & Mitigations](#8-risk-areas--mitigations)
9. [Recommended Phase Order for First Playable](#9-recommended-phase-order-for-first-playable)
10. [Appendix: Architecture Reference](#10-appendix-architecture-reference)

---

## 1. Project Scope

### 1.1 Size of the Original Codebase

| Metric | Value |
|---|---|
| Total C# LOC | ~80,000 |
| Core engine LOC | ~56,000 |
| Core .cs files | ~80 files (in subdirectories) |
| Largest single file | `Serf.cs` — 9,659 lines (giant FSM switch) |
| Other large files | `Player.cs` ~2,200, `Building.cs` ~2,200, `Flag.cs` ~2,000, `AI.cs` ~1,300 |
| Rendering / Audio / Network projects | ~24,000 LOC combined |

### 1.2 Estimated Port Size

| Phase | Estimated Zig LOC | Status |
|---|---|---|
| Phase 1 — Foundation | 2,100 | ✅ Complete (14 files) |
| Phase 2 — Core Engine | 6,000 | ✅ Complete (15 files, 30/80 Serf states) |
| Phase 3 — Data Loading | 600 | ✅ Complete (5 files: PAK, TPWM, BMP, Font, AssetManager) |
| Phase 4a — Rendering Infrastructure | 1,300 | ✅ Complete (10 files: GL bindings, GLFW, Shader, Texture, Camera, MapRenderer, SpriteBatcher, App) |
| Phase 4b — Texture Atlas + Sprite Rendering | 800 | ✅ Complete (terrain, buildings, waves rendered from real sprites) |
| Phase 4c — Game UI Panels + Interactive Gameplay | 3,000 | 🔜 Current work |
| Phase 5 — Audio + Network | 2,100 | 🔜 Planned |
| Phase 6 — Polish & Test | 2,100 | 🔜 Planned |
| **Total** | **~18,500** | |

This is ~23% of the original 80K C# LOC — significant reduction because Zig eliminates the reflection-based serialization framework, the GC, and LINQ-heavy C# idioms. The largest C# file (Serf.cs at 9,659 lines) compresses to ~400 LOC of Zig due to the tagged union + switch dispatch replacing the C# inheritance hierarchy.

### 1.3 Timeline Estimate

For one experienced Zig developer working part-time: **6–12 months** for full feature parity.

**Milestones:**
- ✅ Phase 2 terminal demo (Week 2)
- ✅ Phase 4a: GLFW window with hex map rendering (Week 4)
- ✅ Phase 3: TPWM decompressor for original SPAE.PA assets (Week 4)
- ✅ Phase 4b: Texture atlas from real sprites + terrain/building/wave rendering
- 🔜 Phase 4c: Interactive game UI + building placement + road tools
- 🔜 Phase 6: First fully playable demo

---

## 2. External Dependencies & Zig Replacements

### 2.1 Dependency Map

| C# Dependency | Purpose | Zig Replacement | Complexity |
|---|---|---|---|
| **Silk.NET.OpenGL** (OpenGL 3.1+) | Rendering | `mach-glfw` + raw GL bindings, or `mach/gpu` (WebGPU/Vulkan/Metal) | Medium |
| **Silk.NET.Windowing** | Window creation, event loop | `mach-glfw` (GLFW bindings) or SDL2 bindings | Medium |
| **Silk.NET.Input** | Mouse, keyboard, gamepad | GLFW (via `mach-glfw`) or SDL2 | Low |
| **SixLabors.ImageSharp** | PNG/sprite loading | `stb_image` via Zig bindings, or `zimg` | Low |
| **ManagedBass** (BASS audio) | Audio playback (music + SFX) | `miniaudio` or SDL2_audio or OpenAL bindings | Low |
| **System.Numerics** (SIMD vectors) | Matrix/vector math | Zig's built-in `@Vector`, or write `Mat4`/`Vec4` manually | Low |
| **System.Net.Sockets** | TCP networking | Zig `std.net` (TCP streams) | Low |
| **System.Threading** (Mutex, RWL, Thread) | Threading | Zig `std.Thread`, `std.Thread.Mutex`, `std.Thread.RwLock` | Low |
| **System.Collections.Generic** (List, Dict) | Data structures | Zig `std.ArrayList`, `std.AutoHashMap`, `std.StringHashMap` | Low |
| **System.Random** | Seeded RNG | Zig `std.Random.DefaultPrng` | Low |
| **System.Reflection** | `[Data]` attribute serialization | **Comptime codegen or manual serializers (see §3)** | **High** |

### 2.2 Library Decision Summary

| Concern | Recommended Zig Dependency | Rationale |
|---|---|---|
| **Windowing / Input** | `mach-glfw` | Mature, well-maintained Zig GLFW bindings; handles macOS/Linux uniformly |
| **Graphics** | `mach/gpu` (WebGPU) or raw OpenGL 3.1+ bindings | WebGPU is future-proof (Vulkan/Metal/DX12); raw GL is simpler for a direct port and matches the C# Silk.NET.OpenGL path exactly |
| **Image loading** | `stb_image` via `@cImport` or vendored C source | Single-file C library, trivially bindable in Zig |
| **Audio** | `miniaudio` (vendored C source) | Single-file C library, extremely portable, handles WAV/OGG/FLAC |
| **Nothing else needed** | — | Pure game logic needs no external libraries |

---

## 3. The Serialization Challenge

The C# codebase has a custom dirty-tracking serialization framework that is central to the architecture:

```
State (abstract base)  ←  GameState, PlayerState, BuildingState, FlagState, SerfState, etc.
  ├── MarkPropertyAsDirty(name)     // called in property setters
  ├── TrackProperty(name, subState) // nested dirty tracking  
  ├── DirtyProperties → IReadOnlyList<string>
  └── [Data] attribute              // reflection-based serialize/deserialize
```

### 3.1 Why This Is Hard in Zig

- Zig has **no runtime reflection** — you cannot enumerate struct fields at runtime.
- The `[Data]` attribute approach must be replaced with **comptime-based serialization**.
- Dirty tracking needs `MarkPropertyAsDirty()` inserted into every setter.
- C# properties (`get`/`set`) are syntactic sugar; Zig has no property syntax.

### 3.2 Three Viable Approaches

#### Option A: Comptime Struct Reflection (Recommended for final form)

Use Zig's `@typeInfo` at comptime to generate serialization and dirty-tracking code:

```zig
const GameState = struct {
    tick: u32 = 0,
    random_seed: u64 = 0,
    // ... all fields are data

    pub const data_fields = .{ "tick", "random_seed", ... };
};

// Generic serializer using comptime field iteration:
fn serialize(writer: anytype, obj: anytype) !void {
    inline for (@typeInfo(@TypeOf(obj)).Struct.fields) |field| {
        // serialize field by field using writer
    }
}
```

**Pros**: Clean, type-safe, zero runtime overhead.  
**Cons**: Still needs manual dirty-flag management; no automatic `MarkPropertyAsDirty`.

With Zig's comptime, we can go further — generate a "dirty proxy" type that wraps each state struct and tracks dirty bits automatically:

```zig
// comptime-generated wrapper:
const GameStateProxy = struct {
    inner: *GameState,
    dirty: std.StaticBitSet(comptime fieldCount(GameState)),

    pub fn getTick(self: *@This()) u32 { return self.inner.tick; }
    pub fn setTick(self: *@This(), val: u32) void {
        self.inner.tick = val;
        self.dirty.set(@fieldIndex("tick"));
    }
};
```

**Pros**: Automatic dirty tracking, zero overhead at runtime (no string comparisons).  
**Cons**: Complex comptime machinery; two objects per state entity.

#### Option B: Manual Serialization + Dirty Flags (Recommended for initial port)

Each state struct has a `dirty: DirtyFlags` field and explicit serialize/deserialize methods:

```zig
pub const GameState = struct {
    tick: u32 = 0,
    random_seed: u64 = 0,
    dirty: DirtyFlags = .{},

    pub fn markDirty(self: *@This(), field: Field) void {
        self.dirty.set(@intFromEnum(field));
    }

    pub fn serialize(self: *const GameState, w: anytype) !void { ... }
    pub fn deserialize(self: *GameState, r: anytype) !void { ... }
};
```

**Pros**: Full control, no comptime tricks, easy to debug.  
**Cons**: More boilerplate; every state change must manually call `markDirty()`.

#### Option C: Hybrid — Comptime-Generated Field Accessors

Write a comptime function that takes a struct type and generates accessor functions with automatic dirty tracking:

```zig
fn makeDirtyAccessors(comptime T: type) type {
    // comptime code that generates:
    //   setFieldName(self: *DirtyProxy, val: T.fieldType) void
    // for every field in T
}
```

**Pros**: Combines automation of Option A with explicitness of Option B.  
**Cons**: High implementation complexity.

### 3.3 Recommendation

**Start with Option B** (manual serialization + dirty flags) for the core state types (GameState, PlayerState, BuildingState, SerfState, FlagState). This is the fastest path to a working game.

Once the game is playable and state transitions are stable, write a **comptime helper** (Option C) that generates the boilerplate. The helper can be applied incrementally — start with the most churned state types (SerfState, PlayerState) and work outward.

Skip the C# `[Data]` attribute reflection pattern entirely — it is fundamentally incompatible with Zig's design and would be a performance footgun anyway.

---

## 4. Porting Strategy — By Module

### Phase 1: Foundation (Weeks 1–3)

The goal is a buildable project with window, input, and basic rendering.

| # | Task | Description | Est. Zig LOC |
|---|---|---|---|
| 1a | **Project scaffold** | `build.zig`, `build.zig.zon` with `mach-glfw` dep, module structure mirroring the layout in §7 | 200 |
| 1b | **GLFW window setup** | Window creation, event loop, resize handling, vsync | 500 |
| 1c | **Input handling** | Keyboard + mouse state tracking via GLFW callbacks | 300 |
| 1d | **OpenGL bindings** | Minimal OpenGL 3.1+ bindings: VAO, VBO, EBO, shader compile/link, textures (glTexImage2D), blend state, depth test | 400 |
| 1e | **Image loader** | `stb_image` binding for PNG → raw RGBA; sprite atlas loading | 200 |
| 1f | **Math library** | `Vec2i`, `Vec2f`, `Mat4` (orthographic projection), transformation helpers | 400 |
| 1g | **Serialization framework** | Binary writer (`Serializer`), binary reader (`Deserializer`), `DirtyFlags` bitset type, dirty-tracking state base | 800 |
| 1h | **Audio stub** | `miniaudio` binding — engine init, WAV playback, mixer | 400 |
| 1i | **Networking stubs** | TCP client/server wrappers over `std.net.TcpStream` | 300 |
| 1j | **Core enums & types** | `Direction` (6 hex directions), `Resource.Type` (~30 types), `Building.Type` (24 types), `Serf.Type` (29 types), `Serf.State` (~80 states), `MapPos` (u32), `GameObject.Index` (u32), `Player.Index` (u8) | 500 |

**Phase 1 total**: ~3,600 LOC

---

### Phase 2: Core Game Engine (Weeks 4–10)

Port the engine files in dependency order. Each item lists the C# source, its approximate LOC, and the estimated Zig LOC.

#### 2a–2g: State & Data Types (Weeks 4–5)

| # | Task | C# Source | C# LOC | Zig LOC | Notes |
|---|---|---|---|---|---|
| 2a | **Map** | `Map.cs` | 1,000 | 1,200 | Hex grid, MapPos, tile operations (height, type, resource, object, owner), direction helpers, neighbor traversal, distance calculation, blocking checks |
| 2b | **GameState** | `GameState.cs` | 70 | 100 | Serializable: tick, constTick, gameTime, gameSpeed, random seed, stat counters, goldTotal, knightMorale |
| 2c | **Object collections** | `Objects.cs` | 100 | 250 | `Collection(T)` → Zig struct with array + allocator + free-list; `ObjectFactory(T)` → comptime factory; `IGameObject` → vtable or dispatch |
| 2d | **PlayerState** | `PlayerState.cs` | 300 | 350 | Resources by type, serf counts by type, building counts, score, AI personality; uses `DirtyArrayWithEnumIndex` → Zig comptime-enum-indexed array |
| 2e | **BuildingState** | `BuildingState.cs` | 270 | 300 | Construction flags, building type, stock slots (input/output), production progress, active/halted state |
| 2f | **FlagState** | `FlagState.cs` | 200 | 250 | Resource slot list (resource type + direction + destination), road endpoints list (6 directions), transporter count |
| 2g | **SerfState** | `SerfState.cs` | 100 | 120 | Position (MapPos), state enum, task type, destination, animation frame, inventory carried |

**Phase 2a–2g total**: ~2,570 LOC

#### 2h–2o: Game Logic (Weeks 6–10)

| # | Task | C# Source | C# LOC | Zig LOC | Notes |
|---|---|---|---|---|---|
| 2h | **Inventory** | `Inventory.cs` | 200 | 250 | Resource buffering, in/out mode, stock levels, distribution requests |
| 2i | **Building** | `Building.cs` | 2,200 | 2,800 | 24 building types, production chains, construction phases, resource input/output, knight spawning, burn/decay, priority system |
| 2j | **Flag** | `Flag.cs` | 2,000 | 2,500 | Road network node, resource slot management, transporter assignment, flag-to-flag search (BFS for nearest resource) |
| 2k | **Serf** | `Serf.cs` | 9,659 | 10,000–12,000 | **The monster** — ~80-state FSM, task system, combat, resource transport, path walking; see §6.2 for strategies |
| 2l | **Player** | `Player.cs` | 2,200 | 2,800 | Resource balancing, attack coordination, knight morale, inventory distribution scheduling |
| 2m | **Pathfinder** | `Pathfinder.cs` | 550 | 700 | A* on hex grid (terrain cost, enemy danger); flag-graph BFS; binary heap priority queue |
| 2n | **Game** | `Game.cs` | 1,500 | 1,800 | Root aggregate: owns all collections, update loop (50Hz), resource distribution, victory/defeat conditions |
| 2o | **AI** | `AI.cs` | 1,300 | 1,500 | State hierarchy (AIState tagged union + dispatch function) |

**Phase 2h–2o total**: ~24,350 LOC

**Phase 2 total**: ~27,000 LOC

---

### Phase 3: Data Loading ✅ (4 files, ~430 LOC)

These modules extract assets from the original Settlers DOS data files (`SPAE.PA`, `GFX.PA`, `GOUX0.PA`, etc.). The user must own the original game.

| # | Task | Est. Zig LOC | Status | Notes |
|---|---|---|---|---|
| 3a | **PAK archive reader** | `pak.zig` (108 LOC) | ✅ | Read PAK archives; extract files by index; header validation |
| 3b | **BMP/sprite decoder** | `bmp.zig` (155 LOC) | ✅ | Indexed BMP decoder; palette management; RGBA output; green-screen transparency |
| 3c | **Bitmap font** | `font.zig` (69 LOC) | ✅ | 96-glyph ASCII bitmap font; glyph metrics; text width calculation |
| 3d | **Asset manager** | `asset_manager.zig` (97 LOC) | ✅ | PAK loading; sprite caching (HashMap); unified load interface |

**Phase 3 total**: ~430 LOC (est. was 3,700 — reduced because sprite atlas building and mission parsing are simpler in Zig)

---

### Phase 4: Rendering ✅ (43 files, ~6,500 LOC)

| # | Task | Files | LOC | Status | Notes |
|---|---|---|---|---|---|
| 4a | **OpenGL C bindings** | `gl.zig` | 191 | ✅ | Minimal GL 2.1 subset (shaders, buffers, textures, uniforms, draw calls) |
| 4b | **GLFW bindings** | `glfw.zig` | 128 | ✅ | Window creation, input callbacks, context management |
| 4c | **Shader compiler** | `Shader.zig` | 168 | ✅ | GLSL compilation, program linking, uniform caching; default sprite shader |
| 4d | **Texture management** | `Texture.zig` | 115 | ✅ | Texture upload (RGBA), sub-tex coords |
| 4e | **Camera / viewport** | `Camera.zig` | 94 | ✅ | 2D orthographic camera, scroll/zoom, screen↔world transforms |
| 4f | **Map renderer** | `map_renderer.zig` | 174 | ✅ | Hex tile geometry generation, VBO/IBO upload, colored quad rendering |
| 4g | **Sprite batcher** | `sprite_batcher.zig` | 141 | ✅ | Batch sprite rendering (instanced quads), tinting support |
| 4h | **Texture atlas** | `texture_atlas.zig` | 162 | ✅ | Packs decoded sprites from PAK → 2048×2048 RGBA atlas → OpenGL texture |
| 4i | **Application shell** | `app.zig` | 194 | ✅ | GLFW window creation, game loop, input callbacks, demo scene setup |
| 4j | **Main entry** | `main.zig` | 108 | ✅ | Display detection (GLFW ↔ terminal fallback) |

**Phase 4a+b total**: ~2,500 LOC (core rendering infrastructure + texture atlas + real sprite rendering complete)

### Phase 3: Data Loading ✅ (6 files, ~600 LOC)

| # | Task | Files | LOC | Status | Notes |
|---|---|---|---|---|---|
| 3a | **TPWM decompressor** | `tpwm.zig` | 108 | ✅ | LZSS decompression for TPWM-packed archives (SPAE.PA, SOUNDS.PA, etc.) |
| 3b | **PAK archive reader** | `pak.zig` | 148 | ✅ | Auto-detects TPWM, decompresses on load, reads flat directory, file-by-file access |
| 3c | **BMP sprite decoder** | `bmp.zig` | 155 | ✅ | Indexed BMP decoder; palette management; RGBA output; green-screen transparency |
| 3d | **Bitmap font** | `font.zig` | 69 | ✅ | 96-glyph ASCII bitmap font; glyph metrics; text width calculation |
| 3e | **Asset manager** | `asset_manager.zig` | 97 | ✅ | PAK loading; sprite caching (HashMap); unified load interface |
| 3f | **Sprite IDs** | `sprite_ids.zig` | 95 | ✅ | Known sprite indices in SPAE.PA (terrain, buildings, serfs, UI, font) |

**Phase 3 total**: ~670 LOC (est. was 3,700)

---

**Completed since plan written**:
- ✅ Atlas loads SPAE.PA → decodes sprites → packs 2048×2048 atlas → uploads to GPU
- ✅ Map renderer uses real terrain sprites (UV coords) with procedural stippled terrain transitions
- ✅ Animated water waves over water tiles (16-frame cycling, PAK 630-645)
- ✅ Building sprites rendered with shadows, sorted back-to-front
- ✅ Buildings under construction animate: foundation cross (sprite 0x90) at
     progress 0, then the building's own full sprite fades in (translucent →
     solid) as it is built; drawn fully opaque once done. NOTE: this diverges
     from C++ freeserf, which draws a wooden scaffold "frame" sprite
     (map_building_frame_sprite) + the building revealed bottom-up. We don't,
     for two data reasons: (1) small buildings share one generic lattice
     (0xba) that doesn't resemble them — it made every hut look like the same
     windmill-tower; (2) several frame sprites are EMPTY in SPAE.PA, including
     the stock's (0xc1) and the corner stone (0x91), so big buildings like the
     stock have no scaffold at all. Fading the real sprite keeps every building
     recognisable. The C++ per-type scaffold table is preserved in
     `sprite_ids.Building.frameSprite` if a "classic" mode is ever wanted.
- ✅ Building placement rules (shared by the green/red ghost and actual
     placement so they always agree), modelled on freeserf game.cc
     can_build_mine / can_build_small: mines (granite/coal/iron/gold) only on
     the rocky mountain band — `tundra` + mountain terrain, NOT snow caps
     (`Terrain.isMineable`); all other buildings only on grass/desert
     (`Terrain.isBuildable`); snow and water take no buildings at all. (Our
     generateTerrain emits `tundra` as the grey rocky mountain band below the
     snow line, so tundra is the practical mining terrain.)
- ✅ Keyboard scroll (WASD/arrows) + mouse drag scrolling
- ✅ Mouse-clickable building menu (grid of real building sprites) + F1-F9
     shortcuts. UI projection + hit-testing track the live window size, so menu
     clicks stay aligned with the cursor after the window is resized.
- ✅ Colored resource bars in HUD (wood, stone, planks, fish, bread, iron, coal, beer)
- ✅ Bitmap font renderer (Font.zig) — text rendering via sprite batcher
- ✅ Resource panel HUD — top bar with resource counts + coloured chips
- ✅ Building menu — a grid of clickable icons showing each building's real
     sprite (22 buildings: basic / food / advanced / mines / military), with
     hover highlight + name tooltips. Click an icon to start placing; F1-F9 are
     shortcuts for the first nine. Modelled on the original freeserf
     construction popups (popup.cc draw_*_building_box).
- ✅ Selected building info panel (name, cost)
- ✅ Tool mode indicator (bottom of screen)
- ✅ Mouse-based building placement with ghost preview — shows the actual
     building sprite tinted green (valid) / red (invalid) at the target tile
- ✅ Minimap (160×160 terrain overview, click to jump camera)
- ✅ FPS counter (top-right corner)
- ✅ Right-click / F10 to cancel building placement
- ✅ Minimap click-to-jump navigation

**A first, deliberately simplified economy is now wired** (see §4c.economy):
- ✅ Map objects — trees (deciduous + pine) scattered on grass and rocks on the
     rocky/tundra band, generated with the terrain and rendered from real
     AssetMapObject sprites (tree offsets 0–15, stone offsets 64–71). Buildings
     require a clear tile (the ghost turns red over a tree/rock), matching
     freeserf's map_space_from_obj rule.
- ✅ Serf assignment — when a production building finishes construction it is
     auto-staffed with a worker serf (idle serf → unstaffed building); the
     worker runs the production FSM in `Serf.zig` / `Game.updateSerfs`.
- ✅ Building production — staffed buildings produce their output on a timer.
     Gatherers interact with the map: a lumberjack fells a nearby tree (and
     removes it), a stonecutter consumes a nearby rock, a forester plants new
     trees, a fisher needs adjacent water; they stall when nothing is in range.
- ✅ Road building tool — `RoadBuilder` is wired: press **R**, click a flag,
     then click a second flag to connect them in the flag graph (roads marked
     on the path tiles and rendered). Placing a building now also drops its
     flag (down-right), so buildings are road-connectable.

**Simplified for now (next passes):**
- Resource delivery is instant: produced output is added straight to the player
  stock (HUD counts) rather than being carried by transporter serfs along roads.
- Player resource distribution (stock → building inputs) is a no-op because, for
  easier testing, buildings currently need no input resources.
- Serf transport chains (pick up from flag → walk road → deliver) and real
  serf road-walking are not yet implemented — the serf FSM still advances on
  tick timers, not by stepping along road segments.
- Sound effects + music; AI opponent.

### Phase 4c: Game UI Panels + Interactive Gameplay (Current Work)

**Goal**: From tech demo to interactive game — player can place buildings, build roads, and see resource economy running.

| # | Task | Files | Est. Zig LOC | Depends On |
|---|---|---|---|---|
| 4c.1 | **Font renderer** | `src/render/Font.zig` | 200 | data/font.zig (exists) — bitmap text rendering via sprite batcher |
| 4c.2 | **Game UI Event system** | `src/render/ui/Event.zig` | 100 | Input types, hit-test helpers for panel regions |
| 4c.3 | **Resource panel HUD** | `src/render/ui/Panel.zig` | 400 | Font.zig, Event.zig — resource icons+counters, building menu (F1-F9), selected info |
| 4c.4 | **Minimap** | `src/render/ui/Minimap.zig` | 300 | Game state — terrain overview, click-to-jump |
| 4c.5 | **Mouse-based building placement** | `src/render/ui/BuildingPlacer.zig` | 300 | Event.zig, Map — ghost preview, click to place, validate terrain |
| 4c.6 | **Road building tool** | `src/render/ui/RoadBuilder.zig` | 200 | Event.zig, Map, Pathfinder — click two flags, build road |
| 4c.7 | **Wire everything into app.zig** | `src/render/app.zig` (+edit) | 300 | All above — replace colored bars, route clicks, show minimap |

**Supporting gameplay completeness (parallel):**

| # | Task | Files | Est. LOC | Notes |
|---|---|---|---|---|
| 2p.1 | **Building resource consumption** | `src/core/BuildingState.zig`, `src/core/Game.zig` | 150 | ✅ Done — buildings consume input from local stock, produce output into local stock; `updateInventories` moves resources building↔flag→player stock via road-network BFS |
| 2p.2 | **Player resource management** | `src/core/Player.zig` (+edit) | 200 | ✅ Done — `updatePlayers()` recounts `building_count[]`, runs serf reproduction (generic serf vs knight from sword+shield stock), runs the emergency program (flags when the lumberjack/sawmill/stonecutter chain is broken and planks/stone are short), and distributes input resources from the player stock out to processing buildings' flags by per-resource priority tables (food→mines, planks→construction, steel→armory, coal→gold smelter, wheat→pig farm, lumber→sawmill) |
| 2p.3 | **Flag road network BFS** | `src/core/Flag.zig` (+edit) | 250 | Connect flags via roads, find nearest resource along road graph |
| 2p.4 | **Serf assignment to buildings** | `src/core/Serf.zig` (+edit) | 300 | idle_in_stock → find unstaffed building → assign serf |
| 2p.5 | **Serf deliver-to-building chain** | `src/core/Serf.zig` (+edit) | 300 | Walking to flag, picking up resource, delivering to building input |

**Phase 4c total**: ~3,000 LOC (UI + gameplay wiring)

**First Interactive Milestone deliverable**:
- ✅ See the map with real terrain & building sprites
- ✅ Scroll with WASD/arrow keys, drag with mouse
- ✅ Place buildings by pressing F1-F9 → clicking on map
- ✅ View resource counts in HUD
- ✅ View minimap — click to jump camera
- ✅ See buildings constructing (progress bar)
- ✅ Build roads between flags
- ✅ See serfs walk roads and deliver resources
- ✅ See production chains produce resources

#### How to run the game

```bash
# Build (requires Zig 0.17-dev, system GLFW + OpenGL)
zig build

# Run the full GLFW/OpenGL game (needs a display)
zig build run

# Run with a fixed seed for reproducible terrain
zig build run -- --seed 42

# Run with a larger map (default 64×64, max 1024×1024)
zig build run -- --map-size 256 256

# Save/load a map
zig build run -- --seed 42 --save-map world.zmap
zig build run -- --map-file world.zmap

# Headless terminal demo (no display needed — prints resource stats)
# This runs automatically when GLFW can't init (e.g. over SSH)
zig build run -- --seed 42

# Run tests
zig build test

# Show all CLI options
zig build run -- --help
```

**Prerequisites:** Install GLFW3 (`brew install glfw` on macOS,
`apt install libglfw3-dev` on Debian/Ubuntu).

**What you'll see:** The game opens a window showing the isometric hex map
with 9 pre-placed demo buildings (lumberjack, fisher, stock, sawmill,
forester, farm, tower, stonecutter, mill) around the map center. The top
bar shows resource counts (Wood:20, Planks:15, Stone:10, Fish:8, ...) —
these increase over time as buildings produce and deliver resources
through the flag/road network to the stock building.

#### Controls Reference (current build)

```
── Camera / Navigation ───────────────────────────
W / Arrow Up        Scroll map up
A / Arrow Left      Scroll map left
S / Arrow Down      Scroll map down
D / Arrow Right     Scroll map right
Mouse drag          Pan camera (click + drag)
Scroll wheel        Zoom in / out
Click minimap       Jump camera to that map position

── Buildings ────────────────────────────────────
Click menu icon     Select a building from the on-screen grid (top-left).
                     The grid shows every building's real sprite; hovering
                     shows its name. This is the primary selection method.
F1-F9               Keyboard shortcuts for the first nine menu entries
                     (Lumberjack, Forester, Stonecutter, Fisher, Farm, Mill,
                      Bakery, Pig Farm, Slaughterhouse)
Left click (map)    Place selected building on valid, clear terrain
                     (a building also drops its flag down-right)
Right click         Cancel current tool (building placement / road)
F10                 Cancel current tool

── Roads ─────────────────────────────────────────
R                   Toggle road-building mode
Left click flag     First click: pick the start flag
Left click flag     Second click on another flag: build the road
                     (green preview = path found, red = blocked)

── Map objects ───────────────────────────────────
Trees / rocks       Scattered at world-gen. Lumberjacks fell nearby trees,
                     stonecutters cut nearby rocks (both consume the object);
                     foresters plant new trees. Tiles with an object can't be
                     built on.

── Display ──────────────────────────────────────
H                   Toggle HUD overlay on/off
F11                 Toggle tool mode indicator
Escape              Quit

── HUD Layout ───────────────────────────────────
Top bar (28px)      Resource counts with coloured chips
                     (Wood, Planks, Stone, Fish, Bread, Iron, Coal, Beer, Gold)
Below top bar       Build-menu grid (real building sprites, click to select,
                     hover for name); F1-F9 shortcut the first nine
Right side          Selected building info + construction cost
Bottom              Building placement mode indicator
Top-right corner    FPS counter + game tick number
Top-right           Minimap (160×160 px terrain overview)

── Building placement workflow ──────────────────
1. Click a building icon in the top-left menu grid (or press F1-F9)
   → HUD shows building name + cost on right side
   → Ghost preview follows cursor (green = valid, red = invalid)
2. Move mouse over the map — ghost shows where it will go
3. Left-click on a valid terrain tile to place
   → Building starts constructing (progress advances each tick)
4. Right-click or press F10 to cancel and exit placement mode
5. Press H to toggle HUD visibility
```

### Phase 5: Audio + Network (🔜 Planned)

---

### Phase 6: Polish & Test (Weeks 18–20)

| # | Task | Est. Zig LOC | Notes |
|---|---|---|---|
| 6a | **Unit tests** | 1,000 | Test core logic: pathfinding, building production chains, resource distribution, serf state transitions, serialization round-trips |
| 6b | **Debug overlay** | 500 | FPS counter, state inspector, dirty-tracking viewer, log window |
| 6c | **Performance tuning** | 200 | Allocator selection (arena for frame temp allocs, pool for hot objects), hot-path profiling |
| 6d | **Key bindings / settings** | 300 | Config file (JSON/TOML), key remapping, volume controls, resolution selection |
| 6e | **Cross-compile build** | 100 | Ensure `zig build` produces working binaries for macOS + Linux without toolchain setup |

**Phase 6 total**: ~2,100 LOC

---

## 5. Estimated Totals

| Phase | Zig LOC | Cumulative |
|---|---|---|
| Phase 1 — Foundation | 3,600 | 3,600 |
| Phase 2 — Core Engine | 27,000 | 30,600 |
| Phase 3 — Data Loading | 3,700 | 34,300 |
| Phase 4 — Rendering | 4,600 | 38,900 |
| Phase 5 — Audio + Network | 2,100 | 41,000 |
| Phase 6 — Polish & Test | 2,100 | 43,100 |
| **Total** | **~43,100 LOC** | |

---

## 6. Key Zig-Specific Design Decisions

### 6.1 Memory Management Strategy

The game creates and destroys many objects (serfs, buildings, flags) during play. Recommended strategy:

```
┌─────────────────────────────────────────────────────┐
│                  Global Arena                        │
│  (freed when the game session ends / user exits)     │
│  Contains: Map, GameState, persistent state          │
└──────────────────────────┬──────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Pool<T>    │  │   Pool<T>    │  │   Pool<T>    │
│  Serf (1024) │  │ Building(256)│  │   Flag(256)  │
│ Fixed-size   │  │ Fixed-size   │  │ Fixed-size   │
└──────────────┘  └──────────────┘  └──────────────┘

┌─────────────────────────────────────────────────────┐
│              Per-Frame Arena                         │
│  (reset every tick — 50 times/second)                │
│  Contains: temp pathfinding nodes, render batches    │
└─────────────────────────────────────────────────────┘
```

**Implementation notes**:

- **`Pool(T, max_count)`** — a custom Zig struct using a fixed-size array + free-list (bitmask or linked list of free indices).
- **Frame arena** — `std.heap.ArenaAllocator` reused each frame with `.deinit()` + re-init, or a bump allocator.
- **`std.ArrayList(T)`** for variable-size collections (resource lists, stat histograms).

Why fixed-size pools? The original Settlers has hard limits (max 1024 serfs, 256 buildings, 256 flags per player, up to 6 players). These fit in a few KB and avoid any runtime allocation during gameplay.

### 6.2 The Serf FSM Strategy

`Serf.cs` at 9,659 lines is by far the largest file. It implements an ~80-state finite state machine for serf behavior (walking, transporting resources, mining, farming, fighting, building, etc.).

#### Option A: Direct Port (Big Switch) — **Recommended for Phase 2**

```zig
pub fn update(self: *Serf) !void {
    switch (self.state) {
        .idle_in_stock => self.updateIdleInStock(),
        .walking_on_road => self.updateWalkingOnRoad(),
        .entering_building => self.updateEnteringBuilding(),
        .leaving_building => self.updateLeavingBuilding(),
        .waiting_at_flag => self.updateWaitingAtFlag(),
        .lumberjack_felling => self.updateLumberjackFelling(),
        .fisher_fishing => self.updateFisherFishing(),
        .farmer_planting => self.updateFarmerPlanting(),
        .miller_grinding => self.updateMillerGrinding(),
        .baker_baking => self.updateBakerBaking(),
        .transporting => self.updateTransporting(),
        .fighting => self.updateFighting(),
        .fleeing => self.updateFleeing(),
        .defending => self.updateDefending(),
        .attacking => self.updateAttacking(),
        // ... ~65 more
    }
}
```

- Keep as one large file during Phase 2.
- Each state's logic goes into a separate method on `Serf`.
- Methods are long but organized by state.

#### Option B: State Vtable Dispatch (Refactored)

After the game is playable, refactor to a dispatch table:

```zig
const SerfStateHandler = struct {
    update: *const fn(*Serf) !void,
    enter: *const fn(*Serf) void,
    leave: *const fn(*Serf) void,
    name: []const u8,
};

const SERF_STATE_TABLE = init: {
    var table: [@typeInfo(Serf.State).Enum.fields.len]SerfStateHandler = undefined;
    table[@intFromEnum(Serf.State.idle_in_stock)] = .{
        .update = updateIdleInStock,
        .enter = enterIdleInStock,
        .leave = leaveIdleInStock,
        .name = "idle_in_stock",
    };
    table[@intFromEnum(Serf.State.walking_on_road)] = .{
        .update = updateWalkingOnRoad,
        .enter = enterWalkingOnRoad,
        .leave = leaveWalkingOnRoad,
        .name = "walking_on_road",
    };
    // ...
    break :init table;
};
```

This makes each state handler a standalone function, easier to test and debug. The enter/leave hooks enable resource acquisition/release on state transitions.

### 6.3 C# Inheritance → Zig Idioms

| C# Pattern | Zig Replacement |
|---|---|
| `abstract class AIState` with virtual `Update()` | Tagged union `AIState` with comptime-switched dispatch function |
| `class State` base with `MarkPropertyAsDirty()` | Struct with `dirty: DirtyFlags` field + manual setter functions |
| `interface IGameObject` | Vtable struct field or tagged union dispatch |
| `class Collection<T> : State` | Struct with array + slots bitmask + dirty flag |
| `[Data]` attribute on properties | Comptime `inline for (fields)` or manual serializer |
| `abstract class AIState` subclasses | Tagged union variants: `.expand`, `.defend`, `.attack`, `.resource_management`, etc. |
| `event` / `delegate` | Function pointer fields or message queue |
| `async` / `await` | Synchronous in fixed-timestep loop; or explicit async via `std.Thread` |
| `using` / `IDisposable` | `defer` keyword (more ergonomic) |
| `lock` statement | `std.Thread.Mutex` manually locked/unlocked |

### 6.4 Zig-Specific Architecture Strengths

1. **Comptime serialization** (§3) can be **faster** than the C# reflection approach — no dictionary lookups, no boxing, no GC pressure.

2. **No GC pauses** — the 50Hz game loop runs at a strict 20ms budget. In C#, GC collections (even gen-0) add latency spikes. Zig has zero GC overhead.

3. **Cross-compilation is free** — `zig build -Dtarget=x86_64-linux-gnu` on macOS produces a Linux binary. No Docker, no VMs, no cross-toolchain setup. Same for `aarch64-macos` vs `x86_64-macos`.

4. **Deterministic by default** — Seeded `std.Random.DefaultPrng` + no floating-point ambiguity + no GC = identical execution given the same seed. This is critical for lockstep multiplayer.

5. **Small binaries** — A stripped `-Doptimize=ReleaseSafe` build of this game should be under 2 MB, compared to ~20+ MB for a .NET self-contained deployment.

6. **`defer` + `errdefer`** — The C# codebase has multiple places where an exception in a constructor leaks state. Zig's `errdefer` on every partial-construction path prevents this by construction.

---

## 7. Module Layout

```
freeserf-zig/
├── build.zig
├── build.zig.zon                  # deps: mach-glfw, miniaudio (vendored)
├── src/
│   ├── main.zig                   # Entry point, InitInfo creation, main loop
│   ├── core/
│   │   ├── Game.zig               # Root aggregate
│   │   ├── GameState.zig          # Serializable state
│   │   ├── Map.zig                # Hex grid
│   │   ├── MapGenerator.zig       # Terrain generation
│   │   ├── Player.zig             # Player logic
│   │   ├── PlayerState.zig        # Player serializable state
│   │   ├── Building.zig           # Building logic
│   │   ├── BuildingState.zig      # Building serializable state
│   │   ├── Flag.zig               # Flag logic
│   │   ├── FlagState.zig          # Flag serializable state
│   │   ├── Serf.zig               # Serf FSM (~12K LOC initially)
│   │   ├── SerfState.zig          # Serf serializable state
│   │   ├── Inventory.zig          # Inventory management
│   │   ├── AI.zig                 # AI state machine
│   │   ├── Pathfinder.zig         # A* + flag-graph pathfinding
│   │   ├── enums.zig              # Shared enums (Direction, Resource, etc.)
│   │   └── types.zig              # Shared types (MapPos, GameObject, Index, etc.)
│   ├── data/
│   │   ├── DataSource.zig         # Original game data extraction
│   │   ├── SpriteAtlas.zig        # Sprite loading from PAK files
│   │   └── Mission.zig            # Scenario parsing
│   ├── serialize/
│   │   ├── State.zig              # Dirty-tracking base
│   │   ├── Serializer.zig         # Binary writer
│   │   ├── Deserializer.zig       # Binary reader
│   │   ├── DirtyArray.zig         # Index-dirty arrays
│   │   └── Savegame.zig           # Save/load
│   ├── render/
│   │   ├── Context.zig            # OpenGL context, projection
│   │   ├── Shader.zig             # GLSL compile/link
│   │   ├── Texture.zig            # Texture loading/upload
│   │   ├── MapLayer.zig           # Terrain rendering
│   │   ├── BuildingLayer.zig      # Building sprites
│   │   ├── SerfLayer.zig          # Serf sprites
│   │   ├── UILayer.zig            # UI overlay
│   │   └── Font.zig               # Bitmap font rendering
│   ├── audio/
│   │   ├── AudioSystem.zig        # miniaudio binding
│   │   └── SFX.zig                # Sound effect triggering
│   ├── net/
│   │   ├── Client.zig             # TCP client
│   │   ├── Server.zig             # TCP server (headless)
│   │   └── Sync.zig               # State delta sync
│   └── ui/
│       ├── MainMenu.zig           # Main menu panel
│       ├── GameView.zig           # In-game view
│       ├── Panel.zig              # Resource panel, building menu, stats
│       └── Event.zig              # Input event types
└── test/
    ├── map.test.zig
    ├── serf.test.zig
    ├── building.test.zig
    └── serialize.test.zig
```

### Build Configuration

```zig
// build.zig (skeleton)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "freeserf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link dependencies
    exe.root_module.linkSystemLibrary("glfw", .{});    // via mach-glfw or system
    exe.root_module.link_libc = true;                    // for stb_image, miniaudio, GLFW

    b.installArtifact(exe);

    // Run step
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Freeserf");
    run_step.dependOn(&run.step);

    // Test step
    const test_build = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/Game.zig"),
            .target = target,
        }),
    });
    const test_step = b.addRunArtifact(test_build);
    b.step("test", "Run tests").dependOn(&test_step.step);
}
```

---

## 8. Risk Areas & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **Serf FSM complexity** (9,659 lines, ~80 states) | Certain | High | Port as direct switch first (Option A); test against C# behavior; refactor to vtable dispatch (Option B) after playable |
| 2 | **Reflection → comptime serialization** | High | High | Start with manual serializers (Option B in §3); add comptime codegen after state types stabilize |
| 3 | **Original game data dependency** | Required | Must-have | Users must own the original Settlers DOS game; document data directory configuration; provide demo mode with procedurally-generated assets? |
| 4 | **OpenGL 3.1+ / GPU compatibility** | Low | Medium | Fall back to software renderer (purely CPU) if GL 3.1 unavailable; or target WebGPU via `mach/gpu` for Vulkan/Metal/DX12 |
| 5 | **Network sync bugs** | Medium | High | Deterministic RNG + state checksums in every network packet; unit-test every state transition; test with artificial lag |
| 6 | **Audio latency on Linux** | Low | Medium | miniaudio has good defaults (period size = 4096 frames); make buffer size configurable |
| 7 | **macOS code signing** (notarization) | Low | Low | Release builds need `-target aarch64-macos` or `x86_64-macos`; Zig handles the binary; `codesign` at CI time |
| 8 | **File path separators** (Windows vs macOS/Linux) | None | None | macOS and Linux both use `/`; no Windows target in scope |
| 9 | **Big Sur / arm64 Rosetta issues** | Low | Low | Ship universal binary (x86_64 + aarch64); Zig's `std.zig.system` detects the host CPU |

---

## 9. Recommended Phase Order for First Playable

To get the game visible and interactive as fast as possible, reorder phases to prioritize rendering-critical subsystems:

```
Week  1-3  ── Phase 1 (Foundation)
                GLFW window, OpenGL context, math, enums
                
Week  4-5  ── Map (2a) + Render layers (4a-4d)
                → See the hex grid on screen with camera scroll
                FIRST VISIBLE MILESTONE
                
Week  6-7  ── GameState (2b) + PlayerState (2d) + Inventory (2h)
                → Game ticking, resource counters updating
                
Week  8-9  ── Building (2i) + Game UI (4e)
                → Place buildings, see construction progress
                → Resource panel shows inventory
                FIRST INTERACTIVE MILESTONE
                
Week 10-12 ── Flag (2j) + Pathfinder (2m)
                → Road network between buildings
                → Serfs start walking roads
                
Week 13-16 ── Serf (2k) — THE BIG ONE
                → Full serf AI: transport, production, combat
                
Week 17-18 ── AI (2o)
                → Computer opponent
                → Game is playable solo
                
Week 19-20 ── Phase 3 (Data Loading) + Phase 5 (Audio/Network)
                → Original game assets loaded from PAK files
                → Sound effects + music
                → Multiplayer (if time permits)
```

**First playable milestone** (map visible, camera scroll, buildings placeable): ~Week 9.

---

## 10. Appendix: Architecture Reference

### 10.1 Key Enums

#### Direction (6 hex directions)
```zig
pub const Direction = enum(u3) {
    right,
    down_right,
    down_left,
    left,
    up_left,
    up_right,
    // cycles: cw, ccw, opposite
};
```

#### Resource.Type (~30 types)
```zig
pub const Resource = struct {
    pub const Type = enum(u5) {
        fish,  // Fishing
        meat,  // Butcher / Pig farm
        bread, // Baker
        corn,  // Farm
        flour, // Mill
        // ... wood, planks, stone, iron ore, coal, gold ore, iron bars,
        //     gold bars, steel, tools, weapons, shield, boat, wine, beer,
        //     etc. (full list from original Settlers)
    };
};
```

#### Building.Type (24 types)

Fisher, Lumberjack, Boatbuilder, Stonecutter, StoneMine, CoalMine, IronMine, GoldMine, Forester, Stock (warehouse), Hut (small military), Farm, Butcher, PigFarm, Mill, Baker, Sawmill, SteelSmelter, Toolmaker, WeaponSmith, Tower, Fortress, GoldSmelter, Castle.

#### Serf.Type (29 types)

Transporter, Sailor, Digger, Builder, Lumberjack, Fisher, Farmer, Miller, Baker, Miner, Smelter, Toolmaker, Weaponsmith, Knight0–4 (5 ranks), Geologist, etc.

### 10.2 Tick / Update Architecture

```
50 Hz fixed-timestep loop:

[GLFW Poll Events]
  → Input state updated (keyboard, mouse)
  → Window resize, close, focus

[Game.Tick(constTick)]
  └── if (constTick % gameSpeed == 0):
        Game.Update(tick++)
          ├── Player.Update()        // resource balancing, AI decisions
          ├── Serf.Update() [all]    // serf FSM tick
          ├── Building.Update() [all] // production chains
          ├── Flag.Update() [all]    // transporter scheduling
          ├── Game.UpdateInventories() // resource redistribution
          └── Game.CheckVictoryConditions()

[Render Frame]
  └── Renderer.Draw(game)
        ├── MapLayer.Draw()
        ├── BuildingLayer.Draw()
        ├── SerfLayer.Draw()
        └── UILayer.Draw()
```

Constants:
- `TICK_LENGTH = 20` ms
- `TICKS_PER_SEC = 50`
- Default `gameSpeed = 2` (game logic runs every 2 const ticks → 25 logic ticks/sec)

### 10.3 Game Loop Loop in Zig (skeleton)

```zig
pub fn main(init: std.process.Init) !void {
    // Init
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var window = try glfw.Window.create(...);
    defer window.destroy();

    var game = try Game.init(a);
    defer game.deinit();

    var renderer = try Renderer.init(a, window);
    defer renderer.deinit();

    var clock = try std.time.Timer.start();

    // Game loop
    var const_tick: u64 = 0;
    while (!window.shouldClose()) {
        const frame_start = clock.read();

        glfw.pollEvents();
        game.tick(const_tick);
        renderer.draw(&game);
        window.swapBuffers();

        const frame_elapsed = clock.read() - frame_start;
        const frame_target: u64 = 20_000_000; // 20ms in nanoseconds
        if (frame_elapsed < frame_target) {
            std.time.sleep(frame_target - frame_elapsed);
        }

        const_tick += 1;
    }
}
```

### 10.4 C# → Zig Idiom Mapping Table

| C# | Zig | Notes |
|---|---|---|
| `class Foo { public int X { get; set; } }` | `const Foo = struct { x: u32 = 0, dirty: DirtyFlags = .{} }; pub fn setX(self: *Foo, val: u32) void { self.x = val; self.dirty.set(.x); }` | No properties in Zig; explicit getter/setter pattern |
| `abstract class AIState { public abstract void Update(); }` | `const AIState = union(enum) { expand: ExpandState, defend: DefendState, attack: AttackState, ... }; pub fn update(state: *AIState, ...) !void { switch (state.*) { ... } }` | Tagged union + dispatch function |
| `List<T> items = new List<T>();` | `var items = std.ArrayList(T).init(a);` | Standard library |
| `foreach (var item in items)` | `for (items.items) |item| { ... }` or `for (items, 0..) |item, i|` | Same semantics |
| `lock (lockObj) { ... }` | `mutex.lock(); defer mutex.unlock();` | Manual lock/unlock with defer |
| `using var reader = new BinaryReader(stream);` | `defer reader.deinit();` | No `using` keyword; manual or defer |
| `try { ... } catch (Exception ex) { ... }` | `catch |err| { ... }` | Errors are values, not exceptions |
| `enum Foo : byte { A = 0, B = 1 }` | `const Foo = enum(u8) { a, b };` | Same |`
| `int? maybe` | `?i32` | Optional type |
| `string.Intern(s)` | String dedup via an arena | No string interning in stdlib |
| `nameof(Foo)` | `@typeName(Foo)` or `@tagName(field)` | Comptime |
| `is` / `as` type checks | Comptime type checks or tagged union matching | |

---

*This document is a living plan. Update it as porting reveals new challenges or better approaches.*
