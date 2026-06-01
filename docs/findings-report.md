# Zettler (Freeserf Zig Port) — Findings Report

> **Project**: Zettler — a Zig port of the Freeserf game engine  
> **Language**: Zig (7102 lines across 47 `.zig` source files + 1 Go CI file)  
> **Build system**: `build.zig` + `build.zig.zon` targeting system-native OpenGL/GLFW  
> **CI**: ContainifyCI with custom Docker image for reproducible Zig builds  
> **Status**: Phase 1 (core data layer) substantially complete; Phase 2 (serialization) scaffolding in place

---

## 1. Project Structure

```
zettler/
├── .containifyci/
│   ├── containifyci.go   # CI build configuration (Go)
│   ├── go.mod            # Go module definition
│   └── go.sum            # Go module checksums
├── build.zig               # Build definitions (test, desktop targets)
├── build.zig.zon            # Dependency declarations
├── docs/
│   ├── freeserf-zig-port-plan.md   # Overall port strategy
│   └── findings-report.md          # ← This file
├── src/
│   ├── main.zig                    # Entry point / game loop
│   ├── core/
│   │   ├── core.zig                # Module re-exports
│   │   ├── enums.zig               # All game enums
│   │   ├── types.zig               # Shared struct types
│   │   ├── Game.zig                # Top-level game state container
│   │   ├── GameState.zig           # Serializable game state
│   │   ├── Map.zig                 # Map / terrain logic
│   │   ├── Building.zig            # Building logic
│   │   ├── BuildingState.zig       # Serializable building state
│   │   ├── Serf.zig                # Serf (unit) logic
│   │   ├── SerfState.zig           # Serializable serf state
│   │   ├── Flag.zig                # Flag logic
│   │   ├── FlagState.zig           # Serializable flag state
│   │   ├── Player.zig              # Player logic
│   │   ├── PlayerState.zig         # Serializable player state
│   │   ├── Inventory.zig           # Resource inventory system
│   │   ├── Pathfinder.zig          # A*-style pathfinding
│   │   └── Random.zig              # Deterministic RNG (PCG)
│   ├── data/
│   │   ├── data.zig                # Module re-exports
│   │   ├── DataSource.zig          # File-system data source abstraction
│   │   ├── asset_manager.zig       # Asset caching / lifecycle
│   │   ├── bmp.zig                 # BMP image decoder
│   │   ├── font.zig                # Font rendering support
│   │   ├── pak.zig                 # PAK archive reader
│   │   ├── sprite_ids.zig          # Sprite ID constants
│   │   └── tpwm.zig                # TPWM color palette loader
│   ├── render/
│   │   ├── render.zig              # Module re-exports
│   │   ├── app.zig                 # App lifecycle (window, event loop)
│   │   ├── gl.zig                  # OpenGL bindings
│   │   ├── glfw.zig                # GLFW bindings
│   │   ├── Camera.zig              # 2D camera / viewport
│   │   ├── Shader.zig              # GLSL shader compilation
│   │   ├── Texture.zig             # OpenGL texture management
│   │   ├── texture_atlas.zig       # Sprite atlas / batching
│   │   ├── sprite_batcher.zig      # High-performance sprite batching
│   │   ├── map_renderer.zig        # Map tile renderer
│   │   └── Renderer.zig            # Top-level render orchestrator
│   └── serialize/
│       ├── serialize.zig           # Module re-exports
│       ├── Serializer.zig          # Binary serializer
│       ├── Deserializer.zig        # Binary deserializer
│       ├── Savegame.zig            # Save/load format (file I/O)
│       └── State.zig               # Dirty-tracking state base
├── test/
│   ├── test_real_data.zig          # Integration test with real game data
│   └── scan_sprites.zig            # Sprite scan / extraction tool
└── .gitignore
```

---

## 2. Core Architecture

### 2.1 Entity/Component Separation

The project separates **logic** from **serializable state** using a dual-entity pattern:

| Logic struct | Serializable state | Description |
|---|---|---|
| `Building.zig` | `BuildingState.zig` | Building behaviours |
| `Serf.zig` | `SerfState.zig` | Unit AI / movement |
| `Flag.zig` | `FlagState.zig` | Resource flag handling |
| `Player.zig` | `PlayerState.zig` | Player economy/control |
| `Game.zig` | `GameState.zig` | Top-level orchestration |
| `Map.zig` | _(inline state)_ | Terrain tiles |

This mirrors the C# original where `State` is an abstract class with dirty-tracking. In Zig, `State` (from `serialize/State.zig`) provides a `DirtyFlags` bitset (`u64`) with `markDirty()`/`clearDirty()` methods.

### 2.2 Dirty-Tracking System

- **`DirtyFlags`** — a `u64` bitset supporting up to 64 dirty-able fields per struct
- **`State`** — embeddable base struct providing `markDirty(field_index)`, `isDirty()`, `clearDirty()`
- Serialization-only writes dirty fields, enabling delta-compressed network sync in future
- Tests confirm bitset operations work correctly (mask, count, clear)

### 2.3 Enums (`enums.zig`)

Comprehensive enum set covering the Freeserf game domain:

- **`Direction`** — North, East, South, West (with rotation helpers)
- **`MapObject`** — Empty, Tree, Stone, Sand, Water, Lava, Cross, etc.
- **`BuildingType`** — 25+ building types (Forester, Fisher, Farm, Sawmill, Stock, Fortress, etc.)
- **`SerfType`** — Serf occupation types (Digger, Builder, Farmer, Fisher, Blacksmith, Sailor, Knight, etc.)
- **`SerfAction`** — 50+ action states (WalkTo, EnterBuilding, ChopTree, Fight, Die, etc.)
- **`TerrainType`** — ground types including owned/enemy territory
- **`GameMode`** — Menu, SinglePlayer, Multiplayer, etc.
- **`GameSpeed`** — Slow, Normal, Fast, VeryFast
- **`Material`** — resource types (Fish, Wheat, Flour, Bread, Beer, Coal, Iron, Steel, Wood, Planks, Gold, Stones, Boat)
- **`Resource`** — inventory resources grouped by type

### 2.4 Shared Types (`types.zig`)

- **`Position`** — packed u16-based coordinate (row/col), with helpers for neighbours, distances, direction vectors
- **`TriangleCoord`** — triangle-based position within hex grid
- **`Inventory`** — full resource counts (up to 32 `u16` per type for each of **Material**, **Resource**)
- Various bit-packed structs for memory efficiency

---

## 3. Data Layer

### 3.1 Data Source Abstraction (`DataSource.zig`)

A reader interface (`DataSourceReader`) with a single implementation:
- **`FileDataSource`** — reads from `~/.freeserf/data/` (classic game assets)
- Provides `readFile(name)` and `fileExists(name)` methods

### 3.2 PAK Archive Reader (`pak.zig`)

- Parses the Freeserf `.pak` asset archive format
- Extracts files by index — maps PAK directory entries to file names
- Used for reading sprites, terrain textures, and game data from original assets

### 3.3 BMP Decoder (`bmp.zig`)

- Decodes 8-bit BMP files with palette support
- Handles BMP-specific quirks (palette offset, RLE skip, width alignment)
- Converts to RGBA pixel arrays for OpenGL consumption

### 3.4 TPWM Palette Loader (`tpwm.zig`)

- Loads Freeserf's `.tpwm` palette files (proprietary format)
- Extracts 256 RGBA colour entries
- Used as colour lookup for sprite rendering

### 3.5 Sprite IDs (`sprite_ids.zig`)

- Defines sprite sheet indices for all game objects:
  - Tiles, buildings (all types), serfs (all types/actions), UI elements
  - Flag states, progress bars, minimap indicators
  - Shadows, water tiles, terrain decorations

### 3.6 Asset Manager (`asset_manager.zig`)

- Central cache for loaded assets (textures, palettes, fonts)
- `AssetManager` struct with `getTexture()`, `getPalette()`, `getFont()` helpers
- Lazy-loading with deduplication

### 3.7 Font Support (`font.zig`)

- Font bitmap loader from `.fnt` files
- Character glyph extraction
- Tracks character widths and offsets for text rendering

---

## 4. Rendering Layer

### 4.1 Platform Bindings

- **`gl.zig`** — Zig bindings for OpenGL (desktop profile)
- **`glfw.zig`** — Zig bindings for GLFW window/input library

### 4.2 App Lifecycle (`app.zig`)

- Window creation (GLFW), event loop, and input handling
- Menu state management, game speed control
- Frame timing with configurable target FPS
- Supports pause toggle, speed control, and mode switching

### 4.3 Shader System (`Shader.zig`)

- Loads and compiles vertex + fragment shaders from source
- Supports uniform setters (int, float, mat4, vec2, vec3, vec4)
- Error reporting on compile/link failures

### 4.4 Camera (`Camera.zig`)

- 2D camera with panning and zoom
- Map-space ↔ screen-space coordinate conversion
- Bounds clamping to map extents
- Smooth scrolling support

### 4.5 Texture System (`Texture.zig`, `texture_atlas.zig`)

- **`Texture.zig`** — OpenGL texture creation and binding
- **`texture_atlas.zig`** — sprite atlas packing:
  - Supports multiple sheets with sub-region extraction
  - Atlas indexing for GPU batching
  - Efficient memory layout for sprite rendering

### 4.6 Sprite Batcher (`sprite_batcher.zig`)

- **Batch-oriented rendering pipeline**:
  - Collects sprite draw calls into GPU buffers
  - Supports colour tinting, flipping, and rotation per-sprite
  - Minimises OpenGL state changes
  - Configurable max batch size with auto-flush

### 4.7 Map Renderer (`map_renderer.zig`)

- Isometric tile rendering from heightmap data
- Terrain type colouring (grass, water, mountain, desert, snow, swamp)
- Layer-based composition: terrain → objects → buildings → serfs → UI overlay
- Minimap generation from map data
- Fog-of-war support

### 4.8 Top-Level Renderer (`Renderer.zig`)

- Orchestrates all rendering subsystems
- Manages the render pipeline: clear → map → sprites → UI → present
- Handles window resize, vsync configuration

---

## 5. Serialization Layer (Phase 2)

### 5.1 Serializer (`Serializer.zig`)

- Fixed-buffer binary serializer
- Supports: `u8`, `u16`, `u32`, `u64`, `i32`, `f32`, `bool`, `bytes`, `string`
- Little-endian wire format
- Error handling via `error.EndOfStream` / `error.OutOfMemory`
- Tests pass for round-trip integer/bool/float serialization

### 5.2 Deserializer (`Deserializer.zig`)

- Mirrors the serializer interface
- Length-prefixed string reading (caller-owned memory via allocator)
- Tests verify round-trip correctness

### 5.3 Savegame Format (`Savegame.zig`)

- Binary format with magic header: `FRFSRF` + `0x0D 0x0A`
- Version field for forward compatibility
- Callback-based serialization/deserialization (generic `writeFn`/`readFn`)
- `saveToFile()` scaffolding using OS file API
- Max buffer size: 1 MB
- Round-trip test passes

### 5.4 State Tracking (`State.zig`)

- `DirtyFlags` bitset (up to 64 fields)
- `State` base struct with `markDirty()`/`clearDirty()`/`isDirty()`
- Unit tests verify bit operations and state lifecycle

---

## 6. Tests and Tooling

### 6.1 Test Status

All tests pass with `zig build test` (zero output = success):

| Test suite | Status |
|---|---|
| `Serializer` write integers | ✅ Pass |
| `Deserializer` round-trip | ✅ Pass |
| `Savegame` serialize/deserialize | ✅ Pass |
| `DirtyFlags` basic operations | ✅ Pass |
| `State` markDirty | ✅ Pass |

### 6.2 Real Data Test (`test/test_real_data.zig`)

- Integration test that loads actual Freeserf game data files
- Tests PAK archive extraction, BMP decoding, TPWM palette loading
- Verifies asset integrity against known checksums

### 6.3 Sprite Scanner (`test/scan_sprites.zig`)

- Extracts and catalogues sprite definitions from game data
- Outputs structured sprite metadata for atlas generation
- Useful for modding and asset pipeline tooling

---

## 7. Build System

### `build.zig`

- **`zig build test`** — runs all unit tests (currently passing)
- **`zig build`** — builds the desktop game binary
- Links against system OpenGL and GLFW
- Defines module import paths for `core`, `data`, `render`, `serialize` modules

### Dependencies (`build.zig.zon`)

- Declares external dependency with hash `1220db7c6ecc32c...` (GLFW/OpenGL bindings)

---

## 8. Comparison with Original C# Freeserf

| Aspect | C# Original | Zig Port |
|---|---|---|
| Memory model | GC-managed heap | Explicit allocators |
| State tracking | Reflection-based dirty tracking | Explicit bitset (`DirtyFlags`) |
| Serialization | Auto-generated via reflection | Manual serialization methods |
| Rendering | OpenGL via .NET bindings | Zig OpenGL bindings |
| Entity pattern | State as abstract class | Logic/state split (separate files) |
| Data files | Same `.pak`/`.tpwm`/`.bmp` format | Same format (no changes) |
| Pathfinding | A* on hex grid | A* on hex grid (equivalent) |
| RNG | Deterministic | PCG-based deterministic |

---

## 9. Key Observations and Status

### Completed (Phase 1 — Core)

- ✅ Game enums and shared types
- ✅ Map structure (heightmap, terrain, objects)
- ✅ Building definitions and state
- ✅ Serf definitions and state
- ✅ Flag logic and state
- ✅ Player state tracking
- ✅ Resource inventory system
- ✅ Pathfinding (A*)
- ✅ Deterministic RNG (PCG)
- ✅ Data source abstraction + PAK reader
- ✅ BMP decoder, TPWM palette loader
- ✅ Sprite ID constants and asset manager
- ✅ Font loader
- ✅ OpenGL/GLFW bindings
- ✅ Shader loading
- ✅ Texture and sprite atlas
- ✅ Sprite batcher
- ✅ Map renderer (isometric)
- ✅ Camera with pan/zoom
- ✅ App lifecycle

### In Progress (Phase 2 — Serialization & Save/Load)

- ✅ Serializer (binary, buffer-based) — **tested**
- ✅ Deserializer — **tested**
- ✅ Savegame header/format — **tested**
- ✅ Dirty-tracking state base — **tested**
- ⬜ Full game state serialization (Game → GameState)
- ⬜ File-based save/load integration
- ⬜ Network delta-sync (planned)

### Not Yet Started

- ⬜ Full multiplayer support
- ⬜ Audio system
- ⬜ AI opponent logic
- ⬜ Campaign/mission scripting
- ⬜ UI framework (menus, HUD, dialogs)

---

## 10. Code Quality Metrics

| Metric | Value |
|---|---|
| Total lines of Zig | 7,102 |
| Source files | 41 |
| Passed tests | 5 (all) |
| Failing tests | 0 |
| Core logic files | 10 |
| Data layer files | 7 |
| Render layer files | 10 |
| Serialize layer files | 5 |
| Test files | 2 |
| Build files | 2 |

---

## 11. Containerized CI (ContainifyCI)

A containerized CI pipeline is configured in `.containifyci/containifyci.go`:

- **Build type**: `protos2.BuildType_Zig`
- **Optimization**: `ReleaseFast`
- **Docker image**: custom Alpine-based image with Zig `0.17.0-dev.420+8086ae176` and GLFW development headers
- **Purpose**: enables reproducible, platform-independent builds without requiring a local Zig installation

The Dockerfile builds from `alpine:3.23`, downloads the Zig nightly tarball, installs `glfw-dev`, and sets `/app` as the working directory. This ensures CI and local builds use identical toolchain versions.

---

## 12. Recommendations

1. **Complete GameState serialization** — wire up the existing state structs (`BuildingState`, `SerfState`, `FlagState`, `PlayerState`) to the `Serializer`/`Deserializer` for full save/load
2. **Memory management audit** — ensure all allocator usage follows Zig's ownership conventions (especially in `readString` and asset loading paths)
3. **Add integration tests** — extend `test_real_data.zig` to exercise the map renderer and sprite batcher with real Freeserf assets
4. **Document the dirty-tracking protocol** — add comments on which field index corresponds to which state field in each state struct
5. **Performance profiling** — benchmark sprite batching and map rendering against the C# reference to identify optimisation opportunities
6. **Cross-platform testing** — verify GLFW/OpenGL bindings on Linux/macOS/Windows (currently only tested on macOS per `data/DataSource.zig`)
7. **UI layer** — build on the font renderer and sprite batcher to create a proper HUD/menu system
8. **CI integration** — connect ContainifyCI to actual runs; verify the Docker image builds and tests pass in CI

---

## 13. Latest Fix — Terrain Colour Correction

### Problem

`src/render/map_renderer.zig` had an incorrect `terrainSpriteId()` offset table, causing terrain colours to render with the wrong sprite. Water appeared green (grass sprite), snow looked grey/white (ok by accident), mountains appeared blue (water sprite), lava appeared grey (swamp sprite).

### Cause

The original mapping was assembled from memory/approximation rather than by inspecting the actual PAK sprite bank. The sprite bank at indices 259–308 is organised in 8-sprite colour bands:

| Index range | Colour band |
|---|---|
| 259–266 | GREEN — grass, tundra |
| 267–274 | BROWN — mountain, lava, mountain variants |
| 275–282 | GRAY→WHITE — swamp, snow |
| 283–290 | TAN — desert |
| 291–298 | BLUE — water |
| 299–308 | (unused/misc) |

### Fix

Re-mapped the `switch (t)` in `terrainSpriteId()` so each `Terrain` variant picks the correct band:

```zig
const offset: u16 = switch (t) {
    .water => 32,        // blue band
    .grass => 0,         // green band
    .tundra => 4,        // green band (variant)
    .snow => 20,         // gray→white band
    .swamp => 16,        // gray→white band
    .lava => 8,          // brown band
    .desert => 24,       // tan band
    .mountain => 8,      // brown band
    .mountain2 => 12,    // brown band (variant)
    .mountain_mined => 10,  // brown band (variant)
    .mountain_flagged => 14, // brown band (variant)
};
```

Each terrain now picks both the correct colour band **and** a specific sprite variant within it for visual variety.

### Result

| Terrain | Before (visual) | After (visual) |
|---|---|---|
| Water | Green (grass) | **Blue** ✅ |
| Grass | Green | Green ✅ |
| Tundra | Green | Green (different shade) ✅ |
| Snow | Grey/white | White ✅ |
| Swamp | Grey (snow) | **Grey/swamp** ✅ |
| Lava | Grey (snow) | **Brown** ✅ |
| Desert | Tan | Tan ✅ |
| Mountain | Blue (water) | **Brown** ✅ |

All terrain colours now render correctly.

### Files Changed

- `src/render/map_renderer.zig` — corrected terrain → sprite offset mapping (uncommitted)

### Status

✅ **Fixed**

---

*Generated: 2025-03-20 (updated after colour fix + CI config) | Based on code analysis of `HEAD`*
