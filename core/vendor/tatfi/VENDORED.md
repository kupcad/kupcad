# tatfi in KupCAD

A copy of [tatfi](https://git.sr.ht/~asibahi/tatfi), the font parser KupCAD's `text()` reads its
embedded fonts with (`src/core/text.zig`), taken at v0.1.4 (upstream commit `910aa71`,
2026-10-03). Its files are upstream's (the `src` tree, `build.zig`, `build.zig.zon`, the
license, README and changelog), without upstream's editor and release tooling.

KupCAD's `build.zig` makes the module itself (`tatfiModule`), with the tables `text()` needs:
OpenType layout for kerning, no variable fonts and no Apple tables, which none of the embedded
fonts has. tatfi's tests run in `zig build test` with every table on. tatfi's own `build.zig`
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

## Updating

Copy the files above from a newer upstream commit over these, apply the changes listed here
again unless upstream has them, update the commit above, and run `zig build test` (it runs
tatfi's own tests too).
