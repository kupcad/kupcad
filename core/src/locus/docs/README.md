# Locus

Locus is an exact boundary-representation (B-Rep) solid modelling kernel in Zig: the
engine behind KupCAD's `engine: :brep`, and a library of its own. Nothing in Locus imports
KupCAD.

**Status (2026-11-06): M0, the foundations, nearly done.** Locus is a Zig package of its
own (`build.zig`; `zig build test`, also under wasmtime; `zig build check` for
wasm32-freestanding), pure Zig over `std`. What works: the math layer (exact predicates,
solvers), the geometry of `architecture.md` §5.1 with the full parametric contract and
the NURBS core, interning, the topology of §5.2 with every Euler operator, the checker
(structural, orientation, geometric and the first global rules), tags, the body as JSON, the primitives
(box, cylinder as two half-faces, sphere, cone, torus, the sketch faces, polyhedra), the hull, the BVH,
bounding boxes, every rigid move, uniform scale and mirror, and the STEP writer at full
precision. KupCAD's driver runs on this model; booleans, sweeps, tessellation and the
measures are M1–M5 and are refused until then (`kernel.Feature`, `supports`). The first
attempt was removed in September 2026, and the first skeleton in November; `architecture.md`
§2 says why and what replaced them.

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
8. Deterministic: strict `f64`, no FMA in decisions, iteration by index; a retry picks
   the next direction from a table, never a random one.
9. Every public function documents what it assumes, returns, how it fails and what it
   costs; it takes a `*Diagnostics`, honours `Limits` and the cancel flag.
10. Ideas from other kernels, never their code: OCCT (LGPL), SolveSpace (GPL), SMLib
    (proprietary) and libfive (MPL) are read, not copied. Shewchuk's public-domain
    predicates are ported.
11. A KupCAD script means the same on both engines: same options, same results, same
    refusals (`architecture.md` §9.3). A feature is flipped on in `supports` only after
    KupCAD's parity and invariants tests cover it on both engines.
