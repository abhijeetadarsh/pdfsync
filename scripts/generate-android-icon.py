#!/usr/bin/env python3
"""Generate Android PDF-mark resources from the bundled font.
Requires Python fontTools and rsvg-convert; no font service or image API.
"""
from pathlib import Path
import subprocess
from fontTools.ttLib import TTFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / 'client/android/app/src/main/res'
FONT = ROOT / 'client/assets/fonts/JetBrainsMono-Bold.ttf'
BACKGROUND, FOREGROUND = '#CBA6F7', '#11111B'


def lettering(viewport, font_size):
    font = TTFont(FONT)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = font_size / font['head'].unitsPerEm
    bounds = BoundsPen(glyphs)
    advance = 0
    for letter in 'PDF':
        glyph = glyphs[cmap[ord(letter)]]
        glyph.draw(TransformPen(bounds, (scale, 0, 0, -scale, advance, 0)))
        advance += glyph.width * scale
    left, top, right, bottom = bounds.bounds
    dx, dy = viewport / 2 - (left + right) / 2, viewport / 2 - (top + bottom) / 2
    pen = SVGPathPen(glyphs)
    advance = 0
    for letter in 'PDF':
        glyph = glyphs[cmap[ord(letter)]]
        glyph.draw(TransformPen(pen, (scale, 0, 0, -scale, dx + advance, dy)))
        advance += glyph.width * scale
    font.close()
    return pen.getCommands()


def write(relative, contents):
    dest = RES / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(contents + '\n')


adaptive_path = lettering(108, 22)
vector = '''<?xml version="1.0" encoding="utf-8"?>
<!-- PDF lettering from bundled JetBrains Mono Bold; see assets/fonts/OFL.txt. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="%s" android:pathData="%s" />
</vector>'''
write('drawable/ic_launcher_foreground.xml', vector % (FOREGROUND, adaptive_path))
write('drawable/ic_launcher_monochrome.xml', vector % ('#FFFFFF', adaptive_path))
write('values/launcher.xml', '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">PDF Sync</string>
    <color name="ic_launcher_background">#CBA6F7</color>
</resources>''')
write('mipmap-anydpi-v26/ic_launcher.xml', '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>''')
write('mipmap-anydpi-v33/ic_launcher.xml', '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>''')
legacy_path = lettering(100, 27)
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100"><rect width="100" height="100" fill="{BACKGROUND}"/><path fill="{FOREGROUND}" d="{legacy_path}"/></svg>'''
source = ROOT / 'client/assets/branding/pdf-mark.svg'
source.parent.mkdir(parents=True, exist_ok=True)
source.write_text(svg + '\n')
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    dest = RES / f'mipmap-{density}/ic_launcher.png'
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(dest), str(source)], check=True)
print('Generated PDF Sync legacy, adaptive, and themed Android launcher icons.')
