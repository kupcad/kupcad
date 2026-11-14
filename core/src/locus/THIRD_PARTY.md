# Third-party material in Locus

Locus is pure Zig over the standard library and links nothing. What it takes from
elsewhere is listed here; nothing else is copied.

| What | From | Licence | How it is used |
|---|---|---|---|
| Adaptive-precision predicates `orient2d`, `incircle`, `orient3d` (`src/math/predicates.zig`) | Jonathan Richard Shewchuk, *Adaptive Precision Floating-Point Arithmetic and Fast Robust Geometric Predicates* (1996), `predicates.c` | Public domain | Ported to Zig: the expansion arithmetic and the staged error bounds as published |
| The NURBS algorithms (`src/geometry/nurbs.zig`), by their numbers | Piegl and Tiller, *The NURBS Book*, 2nd ed. | The book's pseudocode, reimplemented | Written from the descriptions, tested on the book's examples |

The other kernels read while planning and building Locus — OCCT (LGPL-2.1), SolveSpace
(GPL-3), SMLib and usd-brep (proprietary), libfive (MPL-2), SolidCraft (MIT OR Apache-2.0)
— contributed ideas and test cases only: data structures, phase orders, tolerance schemes, the lists of what goes wrong.
No code of theirs is in this tree; KupCAD is dual-licensed, so none could be.

OCCT's test suite gave the boolean corpus configurations and expected areas
(`src/boolean/corpus_test.zig`, `degeneracy_test.zig`): the box pairs of
`tests/boolean/bop{common,cut,fuse,tuc}_simple` (A9, B3, C3–C6, D4, D7, F5, G2, G8, H7, H9,
I9, L1, M8, N3, P4, P6, Q9), the pockets of `tests/boolean/bcut_simple` (H1, H4, I3, I4,
J8, K7, K8, K9, L1), and `tests/bugs/modalg_*` buc60801, bug25354_33/34/37, bug27878_6,
bug28485_1 and bug33361. Their coordinates and numbers are restated as Zig table rows, each
crediting its case; the volumes and counts were worked out for Locus; no script text is
copied.

The validators CI runs over Locus's exports (OpenCascade through the OCP bindings for
STEP, the Khronos validator for glTF, lib3mf for 3MF; `core/scripts/`) are test tools
installed in the CI job only: none is linked, vendored or shipped in any build, package or
binding of KupCAD, and nothing is derived from them.

A C or C++ library may be linked by a host of Locus (KupCAD links oneTBB behind the
`Parallel` interface) but not by Locus itself: see docs/architecture.md §4 for the rule.
