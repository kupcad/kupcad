# tatfi in KupCAD

A copy of [tatfi](https://git.sr.ht/~asibahi/tatfi), the font parser KupCAD's `text()` reads its
embedded fonts with (`src/core/text.zig`), taken at v0.1.4 (upstream commit `910aa71`,
2026-10-03). Its files are upstream's (the `src` tree, `build.zig`, `build.zig.zon`, the
license, README and changelog), without upstream's editor and release tooling.

KupCAD's `build.zig` makes the module itself (`tatfiModule`), with the tables `text()` needs:
the characters, the outlines and the names, without OpenType layout (HarfBuzz reads GSUB and GPOS
to shape text), variable fonts or Apple tables, which none of the embedded fonts has. tatfi's tests run in `zig build test` with every table on. tatfi's own `build.zig`
is kept as upstream has it but isn't used: as a dependency its module has no target, so its
tests couldn't run in KupCAD's target and mode.

## Changes from upstream

- `src/tables/colr.zig`: the COLRv1 paint cycle check passes `std.mem.containsAtLeastScalar` its
  arguments in Zig 0.17's order (the element, then the minimum). In the old order it asked for
  `offset` copies of 1 and never matched, so a cyclic paint graph went 64 levels deep instead of
  stopping where the cycle closes. `src/tests/colr.zig` checks it stops there.
- `src/tables/gpos.zig`: `PairSet.get` reads the second glyph's value record with the second
  value format; it used the first's twice, so a pair whose second glyph has no value (as in
  kerning) read past its record and was never found. A value record's Device offsets are taken
  from the start of the PairSet table, as the spec has them, not from past its count.
  `src/tests/gpos.zig` checks both.
- `src/tables/cff/cff1.zig`: a `hintmask` or `cntrmask` after an odd number of operands reads
  the glyph's width before it clears the operand stack. It read it after, an index out of
  bounds: ttf-parser's `clear` keeps the values, Zig's `clearRetainingCapacity` doesn't.
  `src/tests/cff1.zig` has a test of each (KupCAD's font fuzz target found it).
- `src/tables/glyf.zig`: a simple glyph's flag repeat count is read as a `u32` before the flag
  itself is added, as ttf-parser does with `u32::from`. Added in the `u8` it was read as, a repeat
  count of 255 overflowed. `src/tests/glyf.zig` has "a flag repeated 255 times" (KupCAD's font
  fuzz target found it).
- `src/parser.zig`: `Stream.read_bytes` has no debug assert that the end of what it reads fits
  in a `u32`: a count from the font reaches it (a font collection of 0xFFFFFFFF faces, 16
  bytes), and in Debug and ReleaseSafe it panicked. The end is a checked add, and past the data
  it's a parse error, as ttf-parser's release build has it. `src/tests/main.zig`'s "font
  collection num fonts overflow" checks it (upstream had the check commented out as panicking).
- `src/parser.zig`: a `LazyArray` iterator's index saturates. It went one past the end of an
  array of 65535 items, overflowing its `u16` (a font of 65535 table records).
  `src/tests/main.zig` has "a font of 65535 tables".
- `src/parser.zig`: `LazyArray.slice` returns null when the range is out of bounds, as
  ttf-parser's does; it sliced past the data. Its callers, `tables/colr.zig`'s COLRv0 layers and
  `tables/gvar.zig`'s shared tuples, fail on it. `src/tests/colr.zig` has "a base glyph with
  more layers than the table has", `src/tests/gvar.zig` "a tuple whose shared tuple isn't
  there".
- `src/tables/loca.zig`: the number of offsets, one more than maxp's number of glyphs, is
  counted in a `u32`; added in maxp's `u16`, it overflowed on 65535 glyphs, a valid font.
  `src/tests/loca.zig` has "65535 glyphs".
- `src/tables/cmap/format4.zig`: `codepoints` skips a segment that ends before it starts, as
  ttf-parser's `start..=end` does; its range panicked. `src/tests/cmap.zig` has "format4 a
  segment that ends before it starts".
- `src/tables/cmap/format12.zig`, `format13.zig`: `codepoints` counts in a `u32` up to the last
  code point a `u21` holds; counting a `u21` to a group's end past it overflowed. `src/tests/cmap.zig`
  has "format12 a group past the last code point" and the same for format 13.
- `src/tables/cff/charset.zig`: a format 1 range's count of glyphs after its first is widened
  to a `u16` before the first is added, as ttf-parser's `u16::from` does, in parsing the
  charset and in `sid_to_gid`; added in the `u8` it is read as, 255 overflowed, so a valid CFF
  font of 257 glyphs or more could crash `Face.parse`. A format 2 range's count plus one is a
  checked add (ttf-parser's `checked_add`). `src/tests/cff1.zig` has "a charset range of 256
  glyphs" and "a charset range of 65536 glyphs".
- `src/tables/cff/cff2.zig`: a `blend` with nothing on the stack is an error; popping its count
  reached `unreachable`. `src/tests/cff2.zig` has "a blend of no operands".

## Updating

Copy the files above from a newer upstream commit over these, apply the changes listed here
again unless upstream has them, update the commit above, and run `zig build test` (it runs
tatfi's own tests too).
