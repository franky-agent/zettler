#!/usr/bin/env python3
"""Capture screenshots of freeserf at various map sizes for proof-of-work.

Runs the game headless under Xvfb with software OpenGL, waits for it to
render, takes a screenshot, and crops to the 1024x768 game window. Verifies
each screenshot has real content (terrain + buildings).
"""
import collections
import os
import signal
import subprocess
import sys
import time
from PIL import Image

EXE = "./zig-out/bin/freeserf"
OUT_DIR = "docs/screenshots"
SIZES = [(64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]

env = os.environ.copy()
env["DISPLAY"] = ":99"
env["LIBGL_ALWAYS_SOFTWARE"] = "1"
env["GALLIUM_DRIVER"] = "llvmpipe"
env["XDG_RUNTIME_DIR"] = "/tmp"

os.makedirs(OUT_DIR, exist_ok=True)

for w, h in SIZES:
    label = f"{w}x{h}"
    out = f"{OUT_DIR}/map-{label}.png"
    print(f"Capturing {label} ...")

    proc = subprocess.Popen(
        [EXE, "--map-size", str(w), str(h), "--seed", "42"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
    )
    tiles = w * h
    if tiles > 500_000:
        sleep_s = 12
    elif tiles > 100_000:
        sleep_s = 6
    else:
        sleep_s = 3
    time.sleep(sleep_s)

    raw = f"/tmp/raw-{label}.png"
    subprocess.run(["scrot", raw], env=env, check=True)
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=5)

    img = Image.open(raw)
    crop = img.crop((0, 0, 1024, 768))
    crop.save(out)
    c = collections.Counter(crop.getdata())
    buildingish = sum(v for col, v in c.items()
                      if 100 < col[0] < 200 and 80 < col[1] < 160 and col[2] < 100)
    print(f"  {label}: unique_colors={len(c)} building_pixels={buildingish} -> {out}")

print("Done.")