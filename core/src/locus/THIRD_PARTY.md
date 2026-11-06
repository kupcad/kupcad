# Third-party material in Locus

Locus is pure Zig over the standard library and links nothing. What it takes from
elsewhere is listed here; nothing else is copied.

| What | From | Licence | How it is used |
|---|---|---|---|
| Adaptive-precision predicates `orient2d`, `incircle`, `orient3d` (`src/math/predicates.zig`) | Jonathan Richard Shewchuk, *Adaptive Precision Floating-Point Arithmetic and Fast Robust Geometric Predicates* (1996), `predicates.c` | Public domain | Ported to Zig: the expansion arithmetic and the staged error bounds as published |
| The NURBS algorithms (`src/geometry/nurbs.zig`), by their numbers | Piegl and Tiller, *The NURBS Book*, 2nd ed. | The book's pseudocode, reimplemented | Written from the descriptions, tested on the book's examples |

The other kernels read while planning and building Locus — OCCT (LGPL-2.1), SolveSpace
(GPL-3), SMLib and usd-brep (proprietary), libfive (MPL-2) — contributed ideas and test
cases only: data structures, phase orders, tolerance schemes, the lists of what goes wrong.
No code of theirs is in this tree; KupCAD is dual-licensed, so none could be.

A C or C++ library may be linked by a host of Locus (KupCAD links oneTBB behind the
`Parallel` interface) but not by Locus itself: see docs/architecture.md §4 for the rule.
