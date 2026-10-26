"""Makes the BLOND version of the female seasonal outfits by recolouring the hair only.
  python3 make_blond_variants.py      (needs numpy + scipy + Pillow)
How: the hair is found as the big brown region around the head (outlined shapes are separate components, so boots, belts and trim
are left alone); its colours are then matched, by brightness, to the hair of the blond base figure, so the shading stays.
The result goes to character-images/outfit-blond/<name>-blond.png; build_seasonal_images.py embeds them."""
import os, numpy as np
from PIL import Image
from scipy import ndimage as ndi
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'character-images'))
FILES = ['halloween-pirate-f', 'halloween-vampire-f']

def hsv(a):
    rgb = a[..., :3]; mx = rgb.max(2); mn = rgb.min(2); d = mx - mn
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]; dd = np.maximum(d, 1e-6)
    h = np.where(d == 0, 0, np.where(mx == r, ((g - b) / dd) % 6, np.where(mx == g, (b - r) / dd + 2, (r - g) / dd + 4))) * 60
    s = np.where(mx == 0, 0, d / np.maximum(mx, 1e-6))
    return h, s, mx

def lum(rgb): return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]

# reference: the hair of the blond base figure (pixels that differ from the brown base)
bb = np.array(Image.open(os.path.join(ROOT, 'character', 'base-female.png')).convert('RGBA')).astype(float) / 255
bl = np.array(Image.open(os.path.join(ROOT, 'character', 'base-female-blond.png')).convert('RGBA')).astype(float) / 255
diff = (np.abs(bb[..., :3] - bl[..., :3]).sum(2) > 0.12) & (bl[..., 3] > .5)
ref = bl[diff][:, :3]; ref = ref[np.argsort(lum(ref))]
print('blond reference pixels:', len(ref))

for name in FILES:
    im = Image.open(os.path.join(ROOT, 'outfit', 'seasonal', name + '.png')).convert('RGBA')
    a = np.array(im).astype(float) / 255
    h, s, v = hsv(a)
    cand = (a[..., 3] > .5) & (h >= 5) & (h <= 40) & (s > .25) & (s < .85) & (v > .12) & (v < .6)
    lab, n = ndi.label(cand)
    H = a.shape[0]
    keep = np.zeros_like(cand)
    for i in range(1, n + 1):
        ys, xs = np.where(lab == i)
        if len(ys) > 3000 and ys.max() < 0.54 * H: keep |= lab == i       # the big brown regions in the upper half (the hair); belts, boots and trim are lower or smaller
    # soften: also take thin anti-aliased fringes next to the hair
    grown = ndi.binary_dilation(keep, iterations=2) & (a[..., 3] > .5) & (h >= 0) & (h <= 45) & (s > .15) & (v > .1) & (v < .7)
    mask = keep | grown
    print(name, 'hair pixels:', int(mask.sum()))
    out = a.copy()
    L = lum(a[..., :3])[mask]
    order = np.argsort(L); ranks = np.empty_like(order); ranks[order] = np.arange(len(order))
    idx = (ranks / max(len(order) - 1, 1) * (len(ref) - 1)).astype(int)
    out[mask, :3] = ref[idx]
    res = Image.fromarray((out * 255).round().astype(np.uint8), 'RGBA')
    dst = os.path.join(ROOT, 'outfit-blond', name + '-blond.png')
    res.save(dst, optimize=True); print('wrote', dst)
