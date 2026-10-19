# tatfi in KupCAD

A copy of [tatfi](https://git.sr.ht/~asibahi/tatfi), the font parser KupCAD's `text()` reads its
embedded fonts with (`src/core/text.zig`), taken at v0.1.4 (upstream commit `910aa71`,
2026-10-03). Its files are upstream's (the `src` tree, `build.zig`, `build.zig.zon`, the
license, README and changelog), without upstream's editor and release tooling.

## Changes from upstream

- `src/tables/colr.zig`: the COLRv1 paint cycle check passes `std.mem.containsAtLeastScalar` its
  arguments in Zig 0.17's order (the element, then the minimum). In the old order it asked for
  `offset` copies of 1 and never matched, so a cyclic paint graph went 64 levels deep instead of
  stopping where the cycle closes. `src/tests/colr.zig` checks it stops there.

## Updating

Copy the files above from a newer upstream commit over these, apply the changes listed here
again unless upstream has them, update the commit above, and run `zig build test` (it runs
tatfi's own tests too).
