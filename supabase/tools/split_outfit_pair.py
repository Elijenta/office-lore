"""Splits a standard-outfit sheet that holds TWO figures (blond left, brown right) into two single outfits, cleaned up like the others:
  python3 split_outfit_pair.py f6 f7            (needs numpy + scipy + Pillow)
Reads  character-images/outfit/standaard/outfit-<id>.png  and writes
  character-images/outfit/app-458/<id>.png            the brown one
  character-images/outfit-blond/app-458/<id>.png      the blond one
Cleaning: the faint haze (alpha < 24) goes, the grey floor shadow goes, stray specks go, the figure is cropped and resized to the same
458 px canvas as the other outfits. Then run build_standard_outfits.py to embed them in index.html."""
import os, sys, numpy as np
from PIL import Image
from scipy import ndimage as ndi
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'character-images'))
H_OUT, MARGIN_Y, MARGIN_X = 458, 8, 14

def clean(a):
    """a: float RGBA array of one figure -> RGBA uint8 without haze, shadow and specks"""
    al = a[..., 3].copy()
    al[al < 24 / 255] = 0
    rgb = a[..., :3]
    mx, mn = rgb.max(2), rgb.min(2)
    lum = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    grey = ((mx - mn) < 30 / 255) & (lum > 0.5) & (lum < 0.97)          # the soft grey ellipse under the feet: light grey, not the black outline, not skin, not gold
    h = a.shape[0]
    rows = np.arange(h)[:, None] > h * 0.84
    shadow = grey & rows
    # its anti-aliased rim goes with it (pale pixels next to it), the dark outline of the boots / shoes stays
    shadow = shadow | (ndi.binary_dilation(shadow, iterations=3) & rows & ((mx - mn) < 45 / 255) & (lum > 0.38))
    al[shadow] = 0
    # specks: keep only components of reasonable size
    lab, n = ndi.label(ndi.binary_dilation(al > 0.2, iterations=3))
    sizes = ndi.sum(np.ones_like(lab), lab, range(1, n + 1))
    keep = np.zeros_like(al, bool)
    for i, s in enumerate(sizes, 1):
        if s >= 0.03 * sizes.max(): keep |= lab == i
    al[~keep] = 0
    out = np.dstack([rgb, al])
    return (out * 255).round().astype(np.uint8)

def fit(arr):
    im = Image.fromarray(arr, 'RGBA')
    bb = im.getchannel('A').point(lambda v: 255 if v > 12 else 0).getbbox()
    im = im.crop(bb)
    new_h = H_OUT - 2 * MARGIN_Y
    new_w = round(im.width * new_h / im.height)
    im = im.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new('RGBA', (new_w + 2 * MARGIN_X, H_OUT), (0, 0, 0, 0))
    canvas.paste(im, (MARGIN_X, MARGIN_Y), im)
    return canvas

for oid in sys.argv[1:]:
    src = os.path.join(ROOT, 'outfit', 'standaard', f'outfit-{oid}.png')
    a = np.array(Image.open(src).convert('RGBA')).astype(float) / 255
    strong = (a[..., 3] > 0.6).sum(axis=0)
    lo, hi = int(a.shape[1] * 0.42), int(a.shape[1] * 0.58)
    cut = lo + int(np.argmin(strong[lo:hi]))
    halves = {'blond': a[:, :cut], 'brown': a[:, cut:]}
    fitted = {hair: fit(clean(part)) for hair, part in halves.items()}
    W = max(im.width for im in fitted.values())                      # both versions share one canvas size (the app uses one set of sizes for brown and blond)
    for hair, im in fitted.items():
        if im.width != W:
            canvas = Image.new('RGBA', (W, im.height), (0, 0, 0, 0)); canvas.paste(im, ((W - im.width) // 2, 0), im); im = canvas
        d = os.path.join(ROOT, 'outfit-blond' if hair == 'blond' else 'outfit', 'app-458')
        os.makedirs(d, exist_ok=True)
        im.save(os.path.join(d, f'{oid}.png'), optimize=True)
        print(oid, hair, im.size, '->', os.path.relpath(os.path.join(d, f'{oid}.png'), ROOT))
    print(oid, 'split at column', cut)
