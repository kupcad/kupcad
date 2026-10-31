"""Writes the fonts in src/core/test_fonts/ that the text tests shape right-to-left and joining
scripts with: arabic.ttf, hebrew.ttf and devanagari.ttf, each Noto's (SIL Open Font License 1.1,
test_fonts/Noto-OFL.txt) at its Regular weight, holding only the characters the tests draw and
the layout rules (GSUB, GPOS, GDEF) that shape them. Run from core/ with fontTools installed
(`pip install -r scripts/requirements.txt`), the three source fonts in a folder:

    python3 scripts/make-shaping-test-fonts.py path/to/folder

and commit what changes. The sources, from google/fonts:

- ofl/notosansarabic/NotoSansArabic[wdth,wght].ttf (Version 2.012), at 8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5
- ofl/notosanshebrew/NotoSansHebrew[wdth,wght].ttf (Version 3.001), at the same commit
- ofl/notosansdevanagari/NotoSansDevanagari[wdth,wght].ttf (Version 2.007), at 2bc5d431b584d89e646214bf6cfa75494e76ceea
"""

import pathlib
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

OUT = pathlib.Path(__file__).resolve().parent.parent / "src" / "core" / "test_fonts"
# head's created and modified, in seconds since 1904: 2026-10-31, so the files are the same each run
FIXED_TIMESTAMP = 3876249600

# (written, source, the characters the tests draw)
FONTS = [
    ("arabic.ttf", "NotoSansArabic[wdth,wght].ttf", "سلام"),
    ("hebrew.ttf", "NotoSansHebrew[wdth,wght].ttf", "שלום AB"),
    ("devanagari.ttf", "NotoSansDevanagari[wdth,wght].ttf", "कि ab"),
]


def main(folder):
    for written, source, chars in FONTS:
        font = instantiateVariableFont(TTFont(pathlib.Path(folder) / source), {"wght": 400, "wdth": 100})
        options = subset.Options()
        options.layout_features = ["*"]
        options.hinting = False
        options.glyph_names = False
        options.notdef_outline = True
        options.drop_tables += ["STAT"]
        subsetter = subset.Subsetter(options)
        subsetter.populate(text=chars)
        subsetter.subset(font)
        font["head"].created = font["head"].modified = FIXED_TIMESTAMP
        # Saving stamps the time into head.modified unless told not to
        font.recalcTimestamp = False
        font.save(OUT / written)
        print(f"{written}: {(OUT / written).stat().st_size} bytes, {font['maxp'].numGlyphs} glyphs for {chars}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
