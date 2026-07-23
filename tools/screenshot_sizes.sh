#!/usr/bin/env bash
# Capture screenshots of the game running at various map sizes.
#
# Requires: Xvfb, scrot, a built ./zig-out/bin/freeserf, python3+Pillow.
# Usage: ./tools/screenshot_sizes.sh
#
# Produces docs/screenshots/map-<W>x<H>.png for each requested size.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="docs/screenshots"
mkdir -p "$OUT_DIR"

EXE="./zig-out/bin/freeserf"
if [[ ! -x "$EXE" ]]; then
    echo "error: $EXE not found. Run 'zig build' first." >&2
    exit 1
fi

# Ensure Xvfb is running on display :99.
if ! pgrep -f "Xvfb :99" >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb-screenshot.log 2>&1 &
    XVFB_PID=$!
    sleep 1
    echo "Started Xvfb (pid $XVFB_PID) on :99"
fi

export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_RUNTIME_DIR=/tmp

# Map sizes to capture (width height). The minimum is 64 and the maximum 1024.
SIZES=(
    "64 64"
    "128 128"
    "256 256"
    "512 512"
    "1024 1024"
)

for size in "${SIZES[@]}"; do
    read -r W H <<< "$size"
    LABEL="${W}x${H}"
    OUT="$OUT_DIR/map-${LABEL}.png"
    echo "Capturing ${LABEL} ..."

    "$EXE" --map-size "$W" "$H" >/tmp/game-${LABEL}.log 2>&1 &
    GAME_PID=$!
    # Give the game time to initialise, build the atlas, and render a frame.
    # Larger maps allocate and upload much bigger vertex buffers, so scale the
    # warm-up with the tile count.
    TILES=$(( W * H ))
    if   (( TILES > 500000 )); then SLEEP=12
    elif (( TILES > 100000 )); then SLEEP=6
    else                          SLEEP=3
    fi
    sleep "$SLEEP"
    scrot "/tmp/raw-${LABEL}.png"
    kill "$GAME_PID" 2>/dev/null || true
    wait "$GAME_PID" 2>/dev/null || true

    # Crop to the 1024x768 game window.
    python3 - <<PY
from PIL import Image
img = Image.open("/tmp/raw-${LABEL}.png")
crop = img.crop((0, 0, 1024, 768))
crop.save("${OUT}")
print("saved ${OUT}: size", crop.size)
PY
done

echo "Done. Screenshots in ${OUT_DIR}/"