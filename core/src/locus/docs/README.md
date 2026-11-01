# Locus

Locus is an exact boundary-representation (B-Rep) solid modelling kernel in Zig: the
engine behind KupCAD's `engine: :brep`, and a library of its own. Nothing in Locus imports
KupCAD.

**Status (2026-11-02): early.** What works today is the data model (typed indices over two
arenas, half-edges), Euler operators, a validity checker, primitive builders (box,
cylinder, planar sketches, polyhedra; the sphere is still faceted), transforms, a convex
hull, a BVH, a STEP writer for planes and cylinders, and snapshot fixtures. Booleans,
sweeps, trimming, tessellation and the measurements are stubs, and KupCAD's driver refuses
them (`kernel.Feature`, `supports`). An earlier, larger implementation was removed in
September 2026; `architecture.md` says why and what replaces it.

**Read `architecture.md`.** It is the plan: goals and non-goals, the state of the code,
the principles as concrete rules, the package layout, the geometry and topology model,
the tolerance and robustness policy, each operation's pipeline, naming, the checker and
the test strategy, the milestones, and the decisions with their reasons.

## Rules for changes

1. No raw pointers between entities: typed indices into arenas, always.
2. No global state; the allocator and the optional `Parallel` come from the caller.
3. No hard-coded epsilons: every comparison goes through the body's `Tolerance`
   (`zone`, `xsect`, `approx`, `angle`, `param`); `math.EPSILON` only guards division by
   zero.
4. Every traversal is bounded by an entity count, never by a safety counter alone.
5. An operation returns a valid body or an error naming the entity; it never repairs its
   own result and never returns a stand-in.
6. Inputs are never modified; on any failure nothing stays allocated.
7. Tests first, from the books' worked examples; every operation's tests end with the
   checker and the property suite (`architecture.md` §9).
8. Deterministic: strict `f64`, no FMA in decisions, iteration by index.
