"""Makes the BLOND version of a special female outfit by recolouring the long hair only (the hat stays as drawn):
  python3 make_blond_special.py be3          (needs numpy + scipy + Pillow)
How: the hair is the big brown region that touches the left or right side of the figure, below the hat line (everything above row 350 is left
alone); its colours are matched, by brightness, to the hair of the blond base figure, so the shading stays. The vest, skirt and boots are
separate outlined regions and keep their colour. Result: character-images/outfit-blond/outfit-<id>-f-blond.png (lg3: outfit-legend3-f-blond.png) (build_special_outfits.py embeds it)."""
import glob, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'character-images'))
HAT_LINES = {'be3': 350}      # rows above this belong to the (brown) hat of that drawing; 0 = the hat has another colour than the hair, so everything is looked at
FILE_NAME = {'lg3': 'legend3'}

def hsv(a):
    rgb = a[..., :3]; mx = rgb.max(2); mn = rgb.min(2); d = mx - mn
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]; dd = np.maximum(d, 1e-6)
    h = np.where(d == 0, 0, np.where(mx == r, ((g - b) / dd) % 6, np.where(mx == g, (b - r) / dd + 2, (r - g) / dd + 4))) * 60
    return h, np.where(mx == 0, 0, d / np.maximum(mx, 1e-6)), mx
def lum(rgb): return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]

bb = np.array(Image.open(os.path.join(ROOT, 'character', 'base-female.png')).convert('RGBA')).astype(float) / 255
bl = np.array(Image.open(os.path.join(ROOT, 'character', 'base-female-blond.png')).convert('RGBA')).astype(float) / 255
diff = (np.abs(bb[..., :3] - bl[..., :3]).sum(2) > 0.12) & (bl[..., 3] > .5)
ref = bl[diff][:, :3]; ref = ref[np.argsort(lum(ref))]

for sid in sys.argv[1:]:
    HAT_LINE = HAT_LINES.get(sid, 0); fname = FILE_NAME.get(sid, sid)
    src = glob.glob(os.path.join(ROOT, 'outfit', '*', f'outfit-{fname}-f.png'))[0]
    a = np.array(Image.open(src).convert('RGBA')).astype(float) / 255
    h, s, v = hsv(a); H, W = a.shape[:2]
    cand = (a[..., 3] > .5) & (h >= 8) & (h <= 42) & (s > .2) & (s < .9) & (v > .1) & ((v < .62) | ((v < .8) & (s > .42)))
    if HAT_LINE: cand[:HAT_LINE - 30] = False
    lab, n = ndi.label(cand)
    keep = np.zeros_like(cand)
    for i in range(1, n + 1):
        ys, xs = np.where(lab == i)
        if len(ys) < 1200: continue
        if (xs.min() < 0.3 * W or xs.max() > 0.75 * W) and ys.mean() / H < 0.62: keep |= lab == i
    grown = ndi.binary_dilation(keep, iterations=2) & (a[..., 3] > .5) & (h >= 8) & (h <= 45) & (s > .15) & (v > .1) & (v < .8)
    if HAT_LINE: grown[:HAT_LINE - 30] = False
    # dark reddish-brown shading of the hair right next to it (under a red hat brim) belongs to the hair too
    shade = ndi.binary_dilation(keep, iterations=5) & (a[..., 3] > .5) & ((h < 8) | (h > 350)) & (s > .25) & (v > .12) & (v < .5)
    if HAT_LINE: shade[:HAT_LINE - 30] = False
    mask = keep | grown | shade
    mask[int(0.54 * H):] &= v[int(0.54 * H):] > 0.23          # lower down only the lighter brown (the hair); the dark velvet skirt keeps its colour
    L = lum(a[..., :3])[mask]; order = np.argsort(L); ranks = np.empty_like(order); ranks[order] = np.arange(len(order))
    blond = ref[(ranks / max(len(order) - 1, 1) * (len(ref) - 1)).astype(int)]
    w = np.clip((np.where(mask)[0] - (HAT_LINE - 30)) / 40.0, 0, 1)[:, None] if HAT_LINE else 1.0        # fade the recolour in over ~40 rows below the hat line: no hard seam
    out = a.copy(); out[mask, :3] = a[mask, :3] * (1 - w) + blond * w
    dst = os.path.join(ROOT, 'outfit-blond', f'outfit-{fname}-f-blond.png')
    Image.fromarray((out * 255).round().astype(np.uint8), 'RGBA').save(dst, optimize=True)
    print(sid, 'hair pixels:', int(mask.sum()), '->', os.path.relpath(dst, ROOT))
