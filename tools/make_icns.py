#!/usr/bin/env python3
"""Convert Notepad++'s npp.ico into a macOS .icns via iconutil."""
import sys, os, shutil, subprocess, tempfile
from PIL import Image
ico, out = sys.argv[1], sys.argv[2]
im = Image.open(ico)
frames = {}
for size in im.info.get("sizes", {(256, 256)}):
    im.size = size
    im.load()
    frames[size[0]] = im.copy().convert("RGBA")
best = frames[max(frames)]
tmp = tempfile.mkdtemp()
iconset = os.path.join(tmp, "npp.iconset")
os.mkdir(iconset)
for px, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                 (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
                 (512, "512x512"), (1024, "512x512@2x")]:
    src = frames.get(px, best)
    src.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{name}.png"))
subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", out])
shutil.rmtree(tmp)
print("wrote", out)
