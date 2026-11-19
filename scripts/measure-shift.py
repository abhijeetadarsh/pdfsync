# Measure how far the page content moved between screenshots.
# usage: python3 measure-shift.py <dir> a b c ...   (reads <dir>/<name>.full.png)
# Compares row-brightness profiles (x 250..1600, skipping the page thumb);
# a low residual means a clean pure vertical shift.
import sys
from PIL import Image
import numpy as np
def prof(p):
    a = np.asarray(Image.open(p).convert('L'), dtype=np.float32)
    return a[:, 250:1600].mean(axis=1)  # skip page-thumb column on the right
def shift(a, b, lo=500, hi=2400, rng=600):
    best=None
    for d in range(-rng, rng+1):
        s0, s1 = max(lo, lo+d), min(hi, hi+d)
        if s1 - s0 < 600: continue
        diff = np.abs(a[s0-d:s1-d] - b[s0:s1]).mean()
        if best is None or diff < best[0]: best=(diff, d)
    return best
d = sys.argv[1]
names = sys.argv[2:]
for x, y in zip(names, names[1:]):
    r = shift(prof(f'{d}/{x}.full.png'), prof(f'{d}/{y}.full.png'))
    print(f'{x} -> {y}: content moved {r[1]:+d}px (residual {r[0]:.2f})')
