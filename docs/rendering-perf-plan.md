# Rendering Performance & Building-Rendering Fix Plan

## Problem statement

Two regressions appear on large maps (≥ 512×512):

1. **Buildings not rendered correctly on 512×512** — the 9 demo buildings
   disappear or render as fallback rectangles.
2. **General rendering inefficiency** — frame rate collapses as the map grows,
   even though only a small fraction of the map is on screen at any time.

## Root-cause analysis

### A. Buildings vanish on 512×512 — sprite batcher overflow

`renderScene` (app.zig:603) collects **every** map object (trees + rocks) plus
all buildings into a `SceneItem` array, sorts it, then queues each one into the
`SpriteBatcher`. The batcher has a hard cap:

```zig
// sprite_batcher.zig:14
pub const MAX_SPRITES: usize = 16384;
// sprite_batcher.zig:82,102,118
if (self.sprite_count >= MAX_SPRITES ...) return; // silently drops the sprite
```

Estimated object counts (seed 42):

| map size  | tiles   | objects (trees+rocks) | sprites (obj×2) | ×9 offsets | fits 16384? |
|-----------|---------|-----------------------|-----------------|------------|-------------|
| 64×64     | 4 096   | ~470                  | ~940            | ~8 460     | yes         |
| 128×128   | 16 384  | ~1 883                | ~3 766          | ~33 894    | **no**      |
| 256×256   | 65 536  | ~7 536                | ~15 072         | ~135 648   | **no**      |
| 512×512   | 262 144 | ~30 145               | ~60 290         | ~542 610   | **no**      |
| 1024×1024 | 1 048 576 | ~120 585            | ~241 170        | ~2 170 530 | **no**      |

Because `renderScene` is called **9 times per frame** (once per torus offset,
app.zig:542-548) and each call iterates the **entire** map, the batcher fills
up with tree/rock sprites long before it reaches the 9 buildings. The buildings
are sorted *after* the trees by baseline, so by the time the loop reaches them
`sprite_count >= MAX_SPRITES` and every `batcher.add` for a building returns
early — the buildings are silently dropped.

On 64×64 this never triggers (~8k sprites < 16384), which is why it only shows
on larger maps.

### B. Rendering inefficiency — no frustum/viewport culling

Three independent O(map) per-frame costs that do **not** scale with what is
visible:

1. **`renderScene` / `renderRoads` / `renderWaves` iterate every tile.**
   On 1024×1024 that is 1 048 576 tile lookups × 9 offsets = **9.4 M lookups
   per frame**, each doing a `getTileXY` (array index) and an `object != .none`
   check, then building a `SceneItem` and sorting an array of up to 120k
   elements.

2. **`renderScene` allocates `items.len + map.tileCount()` `SceneItem`s every
   frame** (app.zig:615) — up to 1 048 585 × 20 bytes = ~20 MB per frame, just
   to throw most of it away.

3. **`MapRenderer.render` issues 18 `gl.drawElements` calls per frame** (9 base
   + 9 overlay) that each submit the **entire** VBO (up to 4 M vertices / 235 MB
   for 1024×1024). The GPU clips offscreen geometry, but the driver still
   processes the index list and the 3×3 offset loop redundantly re-runs the
   same huge draw 9 times.

The terrain VBO itself is built once (at init) so its size is a one-off cost;
the per-frame cost is the 18 full-VBO draw calls + the CPU-side full-map
iteration in the scene/road/wave passes.

## Fix plan

### Phase 1 — Fix the buildings (correctness, small change)

**Goal:** ensure buildings are always drawn regardless of how many trees/rocks
are on screen.

**Approach:** raise `MAX_SPRITES` and/or split the scene batch so buildings are
queued in a separate batch that cannot be crowded out by map objects.

- **Option A (minimal):** increase `MAX_SPRITES` to e.g. 131 072 so the
  batcher can hold a full 1024×1024 scene in one batch. This is a one-line
  change but increases the pre-allocated vertex buffer from 2.2 MB to
  ~18 MB (4 verts × 32 bytes × 131 072). Simple, but still draws offscreen
  sprites.

- **Option B (cleaner, recommended with Phase 2):** draw buildings in their
  own `batcher.begin()/render()` pass *after* the map-objects pass, so trees
  filling the batcher can never evict buildings. Combined with viewport
  culling (Phase 2) the object pass will rarely overflow.

**Decision:** do **both** — raise `MAX_SPRITES` to 65 536 as a safety net, **and**
split `renderScene` into `renderMapObjects` + `renderBuildings` as separate
batch flushes so buildings are robust against object overflow.

### Phase 2 — Viewport culling for the CPU-side passes (performance)

**Goal:** only iterate/queue/draw sprites for tiles that are actually visible.

**Core idea:** compute the visible world-space rectangle from the camera, convert
it to tile-column/row bounds (with a margin), and loop only over that tile range
instead of `0..map.height × 0..map.width`. Because the map wraps toroidally,
the visible range may wrap — handle that by splitting into at most 4
sub-ranges (like the renderer's 3×3 offset trick, but on the CPU side only the
1 visible offset is needed).

**Steps:**

1. **Add `Camera.visibleWorldBounds() → {min_x, min_y, max_x, max_y}`** —
   returns the world-space rectangle visible through the camera:
   ```
   half_w = viewport_w / (2 * zoom)
   half_h = viewport_h / (2 * zoom)
   min_x = camera.x - half_w, max_x = camera.x + half_w
   min_y = camera.y - half_h, max_y = camera.y + half_h
   ```

2. **Add a world-bounds → tile-range helper** (in app.zig or a new
   `render/culling.zig`). The isometric projection is:
   ```
   screen_x = col * TileW - row * (TileW/2)
   screen_y = row * TileH
   ```
   Inverting for the visible rectangle gives a row range
   `[min_y/TileH - 1, max_y/TileH + 1]` and, for each row, a column range that
   accounts for the shear. A conservative bounding box is sufficient:
   ```
   row_lo = floor(min_y / TileH) - 1
   row_hi = ceil (max_y / TileH) + 1
   col_lo = floor((min_x + row_lo * (TileW/2)) / TileW) - 1
   col_hi = ceil ((max_x + row_hi * (TileW/2)) / TileW) + 1
   ```
   Add a 2-tile margin for sprite footprints (trees/buildings extend above
   their tile). Wrap ranges with `map.wrapX/wrapY`.

3. **Refactor `renderScene` → `renderMapObjects` + `renderBuildings`:**
   - Each loops only over the visible tile range (with wrap handling).
   - Remove the per-frame `SceneItem` allocation for the whole map; use a
     small stack array sized to the visible tile count (at most a few hundred
     tiles at zoom 2 on a 1024×768 window).
   - Keep the back-to-front sort but only over the visible subset.

4. **Apply the same culling to `renderRoads` and `renderWaves`** — both
   currently loop over every tile. Only road/flag tiles and water tiles in
   the visible range need processing.

5. **Reduce the 9-offset scene loop to 1.** The torus 3×3 offset loop
   (app.zig:542-548) is only needed because the camera wraps; with proper
   tile-range wrapping in the culled loop, a single pass covers the visible
   area including any wrap seam. The terrain `MapRenderer.render` keeps its
   9-offset GPU draw (the VBO is static and GPU clipping is cheap), but the
   CPU-side sprite/road/wave passes drop from 9× to 1×.

### Phase 3 — Terrain draw-call reduction (performance, optional)

**Goal:** reduce the 18 full-VBO `gl.drawElements` calls for the terrain.

The terrain VBO is static (built once in `MapRenderer.rebuild`), so the
per-frame cost is purely the 18 draw calls submitting up to 4 M vertices each.
Two options:

- **Option A (simple):** keep the 9-offset base + 9-offset overlay but accept
  that GPU clipping handles offscreen geometry. The driver cost is negligible
  compared to the CPU-side savings from Phase 2. **Recommended — do nothing
  here unless profiling shows the terrain draws are the bottleneck.**

- **Option B (advanced):** split the terrain VBO into a per-chunk grid
  (e.g. 64×64 tile chunks), build a chunk index, and per frame submit only
  the chunks intersecting the visible bounds (with the 3×3 wrap). This
  reduces vertex throughput but adds build-time complexity. **Defer unless
  Phase 2 is insufficient.**

### Phase 4 — Batcher auto-flush (robustness, optional)

Instead of a fixed `MAX_SPRITES` cap that silently drops sprites, make
`SpriteBatcher.add` auto-flush (draw + reset `sprite_count`) when the buffer
is full, so an arbitrarily large visible set renders correctly across multiple
draw calls. This makes the raised `MAX_SPRITES` a throughput hint rather than
a hard correctness limit.

## Implementation order

1. **Phase 1** — raise `MAX_SPRITES` to 65536; split `renderScene` into
   `renderMapObjects` + `renderBuildings` (separate batch flushes). **This
   fixes the 512×512 building bug immediately.**

2. **Phase 2** — add `Camera.visibleWorldBounds`, tile-range helper, and
   cull `renderMapObjects` / `renderBuildings` / `renderRoads` /
   `renderWaves` to the visible range; collapse the 9-offset CPU loop to 1.
   **This fixes the performance regression on all large maps.**

3. **Phase 3** — only if profiling after Phase 2 shows terrain draws dominate.

4. **Phase 4** — auto-flush batcher; nice-to-have for robustness.

## Files touched

| file                     | phase | change |
|--------------------------|-------|--------|
| `src/render/sprite_batcher.zig` | 1, 4 | raise `MAX_SPRITES`; add auto-flush (P4) |
| `src/render/app.zig`     | 1, 2  | split `renderScene` → `renderMapObjects` + `renderBuildings`; add culling to those + `renderRoads` + `renderWaves`; collapse 9-offset loop to 1 for CPU passes |
| `src/render/Camera.zig`  | 2     | add `visibleWorldBounds()` |
| `src/render/culling.zig` | 2     | new file: world-bounds → tile-range helper (with wrap) |
| `docs/custom-map-size.md`| —     | note the perf characteristics |

## Expected impact

| map size | before (sprite lookups/frame) | after (culled, zoom 2) | buildings render? |
|----------|-------------------------------|------------------------|-------------------|
| 64×64    | ~36 k                         | ~36 k (no change)      | yes               |
| 128×128  | ~147 k                        | ~36 k                  | yes (was: no)     |
| 256×256  | ~590 k                        | ~36 k                  | yes (was: no)     |
| 512×512  | ~2.36 M                       | ~36 k                  | yes (was: no)     |
| 1024×1024| ~9.44 M                       | ~36 k                  | yes (was: no)     |

The visible tile count at zoom 2 on a 1024×768 window is roughly
(1024/32)×(768/20) ≈ 32×38 ≈ 1 216 tiles, ×9 for wrap ≈ 11k — well under the
batcher cap. At zoom 1 it is ~4 864 tiles × 9 ≈ 44k sprites, which the raised
65536 cap handles; Phase 4 auto-flush removes the cap entirely.