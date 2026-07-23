# Profiling Guide — CPU & Memory for Zettler/Freeserf

This guide explains **how to gather CPU and memory profiles** for this
project, and lists the **concrete hot spots and leaks the first profiling
pass already found**, with file/line references so they can be fixed.

The project is a Zig 0.17 game (a Settlers reimplementation) that links
GLFW + OpenGL and renders a hex map with sprites. Two execution paths
exist:

| path              | entry                          | needs display? | good for            |
|-------------------|--------------------------------|----------------|---------------------|
| GLFW / OpenGL     | `runGlfwDemo` (main.zig:238)   | yes (`DISPLAY`) | render-loop profiling |
| terminal demo     | `runTerminalDemo` (main.zig)   | no              | headless alloc/mem   |

When `GLFW` init fails (no `DISPLAY`), `main` falls back to the terminal
demo automatically, so memory profiling can run headless.

---

## 1. Tooling available on this machine

| tool          | status        | purpose                                      |
|---------------|---------------|----------------------------------------------|
| `perf`        | installed     | CPU sampling, call graphs, HW counters       |
| `valgrind`    | installed (this session) | heap (massif), memcheck, callgrind |
| `heaptrack`   | installed (this session) | allocation count + leak tracking     |
| `gdb`         | installed     | live debugging, watchpoints                  |
| FlameGraph    | cloned to `/tmp/FlameGraph` | SVG flame graphs from perf data |

> **`perf_event_paranoid` note:** on this host the kernel default is `4`,
> which blocks hardware counters for unprivileged users. `perf record`
> still works (software events), but `perf stat` HW counters come back
> empty. To enable HW counters:
> ```sh
> sudo sh -c 'echo 1 > /proc/sys/kernel/perf_event_paranoid'
> # restore afterwards:
> sudo sh -c 'echo 4 > /proc/sys/kernel/perf_event_paranoid'
> ```

Install the memory tools if they are missing on a fresh machine:
```sh
sudo apt-get install -y valgrind heaptrack
# flamegraph (clone once):
git clone --depth 1 https://github.com/brendangregg/FlameGraph /tmp/FlameGraph
```

---

## 2. Build for profiling

The build uses `b.standardOptimizeOption`, so the optimization level is
selected on the command line. **Always profile a ReleaseFast build** — the
default Debug build has no inlining, bounds checks on every array access,
and is ~50× slower, which hides the real hot spots.

```sh
# ReleaseFast WITH frame pointers (so perf can unwind the stack)
zig build -Doptimize=ReleaseFast -Dno-bounds-check
# Note: Zig 0.17 keeps frame pointers in ReleaseFast by default on x86-64,
# which is what makes perf -g produce readable stacks (see the flamegraphs
# in docs/perf-*-flamegraph.svg that were captured on a Debug build and
# already show full Zig symbol names).
```

If you ever lose stack traces (e.g. after enabling aggressive stripping),
rebuild without strip:
```sh
zig build -Doptimize=ReleaseFast -Dno-bounds-check -Dstrip=false
```

The binary is emitted to `zig-out/bin/freeserf`.

---

## 3. CPU profiling with `perf`

### 3a. Quick counter summary (`perf stat`)

Gives total cycles, instructions, cache and branch misses over a run.
Lower `perf_event_paranoid` first (see §1).

```sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp   # so GLFW opens a window
perf stat -e cycles,instructions,cache-misses,cache-references,\
branch-misses,L1-dcache-load-misses,LLC-load-misses -- \
  timeout 6 ./zig-out/bin/freeserf --map-size 256 256 --seed 1
```

Example result captured on this machine (256×256, 6 s, Debug build):

```
 1,760,053,231  cycles
 2,293,473,970  instructions            (~1.30 IPC)
     4,306,839  cache-misses            (10.6% of cache-refs)
    40,660,158  cache-references
     9,354,225  branch-misses
    18,112,431  L1-dcache-load-misses
 6.04 s elapsed, 0.32 s user
```

> The low IPC (1.30) and 10 % cache-miss rate are typical of the
> data-dependent map-wrapping loops in `Map.wrapX`/`wrapY` and the
> per-sprite hash lookup — see §5.

### 3b. Sampled call graph (`perf record`)

Capture a whole run (includes startup):

```sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
rm -f perf.data
timeout 10 perf record -F 999 -g -- \
  ./zig-out/bin/freeserf --map-size 256 256 --seed 1
perf report -i perf.data --stdio --percent-limit 1 | less
```

**To profile steady-state rendering only (skip startup)**, attach to the
already-running process:

```sh
./zig-out/bin/freeserf --map-size 256 256 --seed 1 >/dev/null 2>&1 &
PID=$!
sleep 3                                  # let startup finish
timeout 8 perf record -F 999 -g -p $PID -o perf-steady.data
kill $PID
perf report -i perf-steady.data --stdio --percent-limit 0.5
```

### 3c. Flame graph (SVG)

```sh
perf script -i perf-steady.data > steady.perf
perl /tmp/FlameGraph/stackcollapse-perf.pl steady.perf > steady.folded
perl /tmp/FlameGraph/flamegraph.pl \
  --title "freeserf — steady-state render (256×256)" \
  steady.folded > docs/perf-steady-flamegraph.svg
```

Open the SVG in a browser; it is interactive (click to zoom). Two
flamegraphs are committed:

- `docs/perf-startup-flamegraph.svg` — whole run (dominated by terrain
  generation + atlas build)
- `docs/perf-steady-flamegraph.svg` — render loop only

### 3d. Per-function annotation (`perf annotate`)

Drill into a single hot function to see which instructions cost the most:

```sh
perf report -i perf-steady.data        # interactive, press 'a' to annotate
# or non-interactive:
perf annotate -i perf-steady.data --symbol=sprite_batcher.SpriteBatcher.add
```

---

## 4. Memory profiling

### 4a. `heaptrack` — allocation frequency & leaks

heaptrack intercepts `malloc`/`free` via `LD_PRELOAD`. **It works
headless on the terminal demo**; for the GL run it sometimes conflicts
with the GL driver's own `LD_PRELOAD`, producing an empty `.zst`. If that
happens, profile the terminal demo (same allocation paths, minus GL
objects) or use valgrind massif (§4b) for the GL path.

```sh
# Headless (terminal demo — force fallback by unsetting DISPLAY):
DISPLAY= heaptrack -o /tmp/ht_zettler \
  ./zig-out/bin/freeserf --map-size 128 128 --seed 1

# Analyze:
heaptrack --analyze /tmp/ht_zettler.zst
```

`heaptrack --analyze` prints several sections: **MOST CALLS TO
ALLOCATION FUNCTIONS**, **PEAK MEMORY LEAKS**, **MOST MEMORY**,
**SUPPRESSED**. For a GUI view: `heaptrack_gui /tmp/ht_zettler.zst`.

First-pass result (terminal demo, 128×128):

```
allocations:            86
leaked allocations:     70      (all in libGLX/libglfw init — see §5)
temporary allocations:  1
peak heap:              ~800 B  (also libGLX strdup)
```

### 4b. `valgrind --tool=massif` — heap+stack growth over time

Massif samples memory at regular intervals and produces a timeline.
Unlike heaptrack it does **not** use `LD_PRELOAD`, so it works reliably
with the GL path (slowly — expect ~20× slowdown).

```sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
valgrind --tool=massif --massif-out-file=/tmp/massif.out.zettler --stacks=yes \
  ./zig-out/bin/freeserf --map-size 256 256 --seed 1 &
# let it run ~20 s, then kill
ms_print /tmp/massif.out.zettler | less
```

`ms_print` shows a text graph of total memory over time and a detailed
breakdown of the peak snapshot. For a GUI: `massif-visualizer
/tmp/massif.out.zettler`.

First-pass peak (terminal demo): **~59 KB total**, of which 56 KB is
**stack** and only ~2 KB is heap (all from libGLX `dlopen` init). The Zig
code itself uses an **arena allocator** (main.zig:216) so it never frees
individual allocations — see §5, finding M1.

### 4c. `valgrind --tool=memcheck` — invalid reads/writes, leaks

```sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all \
  --track-origins=yes \
  ./zig-out/bin/freeserf --map-size 64 64 --seed 1 2>&1 | tee memcheck.log
```

Use a small map and short run; memcheck is ~30× slower. Suppress the
known GL/libc noise with a suppressions file if reviewing leaks.

### 4d. `valgrind --tool=callgrind` — instruction-level CPU profile

When `perf` is not available (e.g. restricted kernel), callgrind gives an
exact call graph (no sampling):

```sh
valgrind --tool=callgrind --callgrind-out-file=/tmp/call.out \
  ./zig-out/bin/freeserf --map-size 64 64 --seed 1
callgrind_annotate /tmp/call.out | less
# or GUI: kcachegrind /tmp/call.out
```

---

## 5. Findings from the first profiling pass

These are real numbers from the Debug build on this machine. They tell
you **where to look first**; re-profile after each fix.

### CPU — steady-state render loop (256×256, zoom default)

| % self | function                          | file:line              | issue |
|--------|-----------------------------------|------------------------|-------|
| 42.6 % | `SpriteBatcher.add`               | sprite_batcher.zig:115 | called per-sprite, writes 4 vertices; see C1 |
| 14.7 % | `hash.wyhash` / `AutoHashMap.get` | texture_atlas.zig:160  | per-sprite atlas lookup hashes a u16; see C2 |
|  9.6 % | `std.mem.sort` (SceneItem)        | app.zig:668            | re-sorts all visible objects every frame; see C3 |
|  7.96% | `culling.TileIter.next`           | culling.zig            | per-tile wrap math; see C4 |
|  7.81% | `Map.wrapX` / `wrapY`             | Map.zig                | called from several hot loops; see C4 |
| 14.1 % | `glfw.swapBuffers` (driver)       | libgallium             | not our code — GPU/buffer-swap; ignore unless vsync off |

**C1 — `SpriteBatcher.add` vertex write (sprite_batcher.zig:115-130)**
Each `add` stores 4 `SpriteVertex` (8 × f32 = 32 B each, 128 B/sprite)
with per-field struct literals. This is the single biggest CPU cost.
Possible improvements:
  - Make `SpriteVertex` `extern struct` (guaranteed no padding) and
    `@memcpy` a 128-byte block instead of 4 field-wise literals.
  - Or build the vertex data in a tighter inner loop in `drawMapObject`
    and bulk-`@memcpy` into `self.vertices[vi..]`.
  - The `if (self.vertices.len == 0) return` and `sprite_count >= MAX`
    checks are cheap but run per sprite; hoist the capacity check out of
    the inner loop in the caller.

**C2 — `TextureAtlas.get` hash lookup (texture_atlas.zig:40,160)**
`entries: std.AutoHashMap(u16, AtlasEntry)`. Every `drawShadowedSprite`
(app.zig:882-883) does **two** `get` calls (sprite + shadow), each
running `wyhash` over the u16 key. For 143 sprites a **direct array**
indexed by sprite id (sized to the max id, or a small perfect hash) would
replace a hash+probe with one indexed load. This alone should remove
~15 % of the frame time.

**C3 — Per-frame sort of map objects (app.zig:668)**
`renderMapObjects` collects visible tiles with objects into `list`,
then `std.mem.sort` by `baseline` **every frame**. The object layout
does not change between frames unless the camera moves, and even then
the relative order only shifts locally. Options:
  - Only re-sort when the camera position/zoom changed (cache the last
    camera matrix).
  - Use insertion sort (nearly-sorted input) instead of `std.mem.sort`.
  - Or sort by tile row (precomputed) and merge.

**C4 — `Map.wrapX`/`wrapY` called from multiple hot loops**
`wrapX`/`wrapY` do a modulo on every tile access. `culling.TileIter.next`
and `renderRoads` both call them heavily. Since the visible tile range is
already bounded by the culler, the inner loops could avoid wrapping by
clamping once at the iterator boundary instead of per-tile.

### CPU — startup (256×256)

| % self | function                       | file:line        | issue |
|--------|--------------------------------|------------------|-------|
| 17.7 % | `Noise.perlin2d`               | Noise.zig        | terrain generation; called once at startup |
| 23.3 % | `MapRenderer.rebuild`          | map_renderer.zig | rebuilds VBO once at startup (and on atlas change) |
| 15.2 % | `heightAtWrapped`              | map_renderer.zig | called from rebuild; same wrap issue as C4 |

Startup is a one-time cost, but for large maps (1024×1024) it becomes
multiple seconds. `perlin2d` and `heightAtWrapped` are the targets;
`heightAtWrapped` shares the `wrapX`/`wrapY` problem (C4).

### Memory

**M1 — Arena allocator hides per-frame leaks (main.zig:216)**
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
```
The whole program uses a single arena that is freed only at exit. This
means:
  - **valgrind/heaptrack will report every allocation as "leaked"**
    because they are never individually freed.
  - **Per-frame allocations accumulate**: `renderMapObjects` (app.zig:649)
    and `renderBuildings` (app.zig:708) fall back to
    `std.heap.page_allocator.alloc` when the stack buffer overflows —
    those are freed with `defer` (good), but any *other* per-frame
    allocation that is not defer-freed will grow the arena forever.
  - To find real per-frame growth, **temporarily** switch `main` to a
    `GeneralPurposeAllocator` (which tracks leaks) and run the GL loop
    for many frames, then check the GPA report on exit.

**M2 — `page_allocator` used directly in hot paths**
Several places use `std.heap.page_allocator` directly instead of the
app's allocator:
  - `renderMapObjects` app.zig:649: `std.heap.page_allocator.alloc(SceneItem, …)`
  - `renderBuildings` app.zig:708: `std.heap.page_allocator.alloc(EntryType, …)`
  - `map_renderer.zig:262`: `const allocator = std.heap.page_allocator;`
  - `Panel.zig:305`: `std.fmt.allocPrint(std.heap.page_allocator, …)`
  - `Shader.zig:36`: `std.heap.page_allocator.alloc(u8, log_len)`
`page_allocator` does a syscall (`mmap`) per alloc — fine once, bad in a
hot loop. The fallback in renderMapObjects/renderBuildings is guarded by
`defer free`, so it is not a leak, but if the visible tile count exceeds
the stack buffer (4096 / 1024) it will `mmap`+`munmap` **every frame**.
Fix: reuse a persistent scratch buffer stored in `App` (allocate once in
`init`, free in `deinit`).

**M3 — Reported "leaks" are all in libGLX/libglfw init**
heaptrack and massif both show the only heap allocations come from
`__GI___strdup` inside `libGLX.so` during `_dl_init` (GL driver loads its
ICD by name). These are not Zettler leaks and can be suppressed. The Zig
code's own heap footprint (via the arena) is a single contiguous block
that massif reports as one big allocation.

**M4 — `SpriteBatcher` pre-allocates fixed buffers (good)**
`SpriteBatcher.init` allocates `MAX_VERTICES` (65536×4) and `MAX_INDICES`
(65536×6) once — about 5 MB total — and reuses them. This is the right
pattern; no per-frame allocation here. The only concern is that the
fixed `MAX_SPRITES = 65536` cap means a very zoomed-out 1024×1024 view
will auto-flush mid-frame (correct but costs extra draw calls).

---

## 6. Recommended profiling workflow

1. **Build ReleaseFast**: `zig build -Doptimize=ReleaseFast`
2. **Lower paranoid** (once): `sudo sh -c 'echo 1 > /proc/sys/kernel/perf_event_paranoid'`
3. **perf stat** (counters): §3a — confirms cache/branch pressure.
4. **perf record steady-state** + flamegraph: §3b/3c — shows the hot
   call graph. Compare before/after each fix.
5. **heaptrack** (terminal demo): §4a — cheap, finds allocation hot
   spots and leaks.
6. **massif** (GL run): §4b — confirms peak RSS and whether it grows
   over time (run for 60 s, check the graph is flat).
7. **memcheck** (small map, short run): §4c — catches invalid reads
   after refactors.
8. **Restore paranoid**: `sudo sh -c 'echo 4 > /proc/sys/kernel/perf_event_paranoid'`

### Quick "did I regress?" one-liner

```sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
./zig-out/bin/freeserf --map-size 256 256 --seed 1 >/dev/null 2>&1 & PID=$!
sleep 3; timeout 5 perf record -F 999 -g -p $PID -o /tmp/before.data
kill $PID
# … make your change + rebuild …
./zig-out/bin/freeserf --map-size 256 256 --seed 1 >/dev/null 2>&1 & PID=$!
sleep 3; timeout 5 perf record -F 999 -g -p $PID -o /tmp/after.data
kill $PID
perf diff /tmp/before.data /tmp/after.data
```

---

## 7. Fix priority (from the data above)

| # | change                              | file(s)              | expected gain | effort |
|---|-------------------------------------|----------------------|---------------|--------|
| 1 | Replace `AutoHashMap` atlas lookup with direct array | texture_atlas.zig | ~15 % frame | low |
| 2 | Bulk-write vertices in `SpriteBatcher.add` | sprite_batcher.zig | ~10-20 % | low |
| 3 | Cache the object sort across frames | app.zig:668 | ~10 % | medium |
| 4 | Avoid per-tile `wrapX/wrapY` in inner loops | Map.zig, culling.zig, map_renderer.zig | ~8 % + startup | medium |
| 5 | Replace per-frame `page_allocator` fallbacks with a reused `App` scratch buffer | app.zig:649,708 | removes mmap-per-frame | low |
| 6 | (optional) Switch `main`'s arena to GPA when profiling to catch per-frame leaks | main.zig:216 | diagnostic | low |

The existing `docs/rendering-perf-plan.md` already identified the
batcher-overflow and missing-culling problems (Phase 1-4); the culling is
now in place (that's why `TileIter.next` appears instead of a full-map
scan). The remaining wins are the micro-optimizations in the table above.