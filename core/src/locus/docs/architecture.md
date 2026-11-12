# Locus architecture and plan

Locus is an exact boundary-representation (B-Rep) solid modelling kernel in Zig. It is the
engine behind KupCAD's `engine: :brep`, and a library in its own right: nothing in Locus
imports KupCAD, and anything that can call Zig (or, later, C) can use it.

This document is the plan for building it. It records the state of the code, the design
decisions and why they were made, the modules and their contracts, how the work is tested,
and the order it is done in. It replaces the earlier `docs/README.md` and `architecture.md`,
which described a version of the kernel that was deleted in September 2026 (§2).

Sources behind the decisions: Stroud, *Boundary Representation Modelling Techniques*
(2006, cited "S p.N"); Hoffmann, *Geometric and Solid Modeling* (1989, "H p.N"); Piegl &
Tiller, *The NURBS Book* 2nd ed. ("A2.1" = algorithm numbers); Farin, *Curves and Surfaces
for CAGD* 3rd ed. and the *Handbook of CAGD* ("HB ch.N"); de Berg et al., *Computational
Geometry* 3rd ed. ("BKOS p.N"); Ericson, *Real-Time Collision Detection* ("RTCD p.N");
the OCCT, SMLib/usd-brep, SolveSpace and libfive sources.

---

## 1. Goals and non-goals

**Goals**

1. Exact geometry: a cylinder is a cylinder, a circle a circle, a boolean of two exact
   solids an exact solid whose faces lie on the input surfaces (H p.70). Approximation is
   allowed only where no closed form exists (a general intersection curve), and is then
   recorded with its tolerance.
2. Every operation returns a valid solid or a clear error. Never a stand-in, never a
   repaired guess, never a hang.
3. Deterministic: the same inputs give the same bytes on every platform and thread count.
4. Usable by KupCAD through a thin adapter (`kernel/engines/brep/driver.zig`), and by
   other programs through the same Zig API (and a C API later). In KupCAD a script means
   the same on either engine: same options, same results, same refusals, checked by
   tests (§9.3).
5. Small enough for a small team to understand whole. OCCT's modelling toolkits are ~1M
   lines; SolveSpace's whole NURBS kernel is 6.6k. Locus aims at the order of 30–40k lines
   including tests, by choosing what not to build (below).

**Non-goals (YAGNI)**

- Non-manifold topology (radial edges, wire and vertex shells). Booleans that would need
  them return several shells or bodies instead (S p.126–127, p.122 on radial-edge
  ambiguity).
- A general healer for foreign B-Reps. Locus produces valid output or fails; SMLib's
  20-stage healer exists to repair its own and others' results, and its known issues are
  mostly the healer's (usd-brep `KNOWN_ISSUES.md`).
- Feature history, constraints, assemblies, rendering. KupCAD's DAG owns history.
- Per-entity "tolerant" modelling in ACIS's sense. One tolerance per body (§6).
- Implicit (F-rep) modelling inside Locus. libfive shows offsets and blends are easy in
  F-rep, but the way back to a B-Rep is lossy; KupCAD already has Manifold for mesh-only
  results.
- Floating-point formats other than `f64`; exact rational arithmetic for constructions
  (H p.124–137: fine for planes, breaks on rotations and quadrics).

---

## 2. Where the code is today

**2026-11-06, M0 in progress.** The skeleton described below was replaced, item by item of
`backups/locus-plan/MILESTONES.md`, by the model of §5 on branch `locus-next`: the layout
of §4 stands, every public operation takes `*Diagnostics` and `Options`, the checker is
the oracle of every test, and KupCAD's driver runs on it. What the driver still refuses
(`supports`) is what M1–M5 build. The paragraphs below describe the skeleton as it was on
2026-11-02, for the record of what was wrong with it.

`core/src/locus` held 6,136 lines. What worked: typed indices and the two arenas,
half-edges with twins, Euler operators `mev/mef/kef/kev/kemr`, a validity checker,
primitive builders (box, cylinder as two half-faces with seam edges, square, circle,
polygon, even-odd polygons, polyhedron), transforms, quickhull, a flat AABB BVH, a
checkpoint/rollback, point interning by linear scan, an Eigen bridge (Levenberg–Marquardt,
determinants, PCA normal, exact `orient2d`/`incircle`), a STEP writer for planes,
cylinders, circles and lines, JSON snapshot fixtures, and a `parallelFor` over oneTBB.

What is a stub returning a fixed value: booleans (3D and 2D), extrude, revolve, loft,
trim/split by plane, slice, tessellation, projection, face queries, volume, area, genus,
bounding box, Minkowski. KupCAD's driver refuses all of them through `supports`.

Defects in what exists, each fixed by the model in §5: no edge entity, so an edge's
parameter interval and tolerance have nowhere to live (a `CircleArc` is a full circle); the
face→loops `(start, len)` ranges break when `kemr` adds a loop to a face that isn't last;
the sphere is a 16×8 faceted polyhedron; transforms copy only lines and planes; NURBS
evaluation is recursive Cox–de Boor without span search, derivatives or knot insertion;
point projection on NURBS is a 9×9 grid search; the Euler check accepts any even χ ≤ 2;
interning is O(n²); the docs described a deleted implementation.

**The first attempt.** Between 2026-09-04 and 09-19 Locus had 14,635 lines: a boolean
built from face slicing by 3D segments followed by vertex welding and coplanar merging,
an LM-driven NURBS surface–surface marcher, a Bowyer–Watson tessellator, sweeps,
fillets, a healer, stress and fuzz tests. Commit `75b68678` removed it deliberately: the
decision was to finish the language and the mesh kernel first and come back to the B-Rep
once it was clear what KupCAD needs from it, and the first attempt had been built without
a plan. Its tests are still instructive: 21 "Hang Test" cases in the healing suite alone,
and "Healed Solid Fails Manifold Validation". The pipeline split faces first and repaired
afterwards, with no invariant the intermediate states satisfied, so each fix exposed
another cycle. This plan keeps the model valid between every step (S p.125), decides each
geometric incidence once (H p.81–82), never repairs inside an operation, and bounds every
traversal by construction.

---

## 3. Principles, made concrete

Each principle is a rule the code is held to, not a slogan.

**Data-oriented design**
- Entities live in struct-of-arrays arenas addressed by typed `u32` indices (`enum(u32)`);
  no pointers between entities, ever. Relationships that are one-to-many (face → loops,
  shell → faces, body → shells) are intrusive index lists (`first`, `next`), so inserting
  a loop into any face is O(1). Read-only consumers (tessellation, export, BVH build) may
  build compressed ranges from them when it pays.
- Geometry is one array per kind (`planes`, `cylinders`, …, `nurbs_surfaces`), referenced
  by a packed `{kind: u8, index: u24}`. Dispatch is one `switch` per batch, exhaustive at
  compile time, not a vtable per entity.
- Algorithms produce their intermediate state as tables (intersection events, paves,
  fragments, classifications) that can be dumped and tested, not as recursion.
- Deletion is a tombstone bit; `compact()` renumbers once at the end of an operation and
  returns the remap tables (SolveSpace's `newH`).

**SOLID**
- *Single responsibility*: one module per concern (§4). The boolean orchestrator contains
  no geometry; the intersector knows no topology; the checker mutates nothing.
- *Open–closed*: adding a surface kind means a new array, a new `switch` arm in the
  evaluator (the compiler lists every place), and nothing in topology or booleans.
- *Liskov*: every curve and surface honours one parametric contract (§5.1): domain,
  periodicity, evaluate, derivatives, normal, project, bounds. Algorithms are written
  against that contract.
- *Interface segregation*: a host sees `Body`, the operations, `Tolerance`, `Resolution`,
  and the result types. Nothing else is `pub` at the root.
- *Dependency inversion*: Locus imports only `std`. The host supplies the allocator and,
  optionally, a `Parallel` work-splitter. No global state, no `std.log` decisions.

**KISS**
- Analytic first: planes, cylinders, cones, spheres, tori, lines, circles, ellipses, plus
  two exact swept surface kinds (linear extrusion and revolution of a curve) cover every
  primitive KupCAD makes and every extrude/revolve of a sketch of lines and arcs. NURBS is
  reached only by lofts, sweeps along paths and general intersections.
- Faces are never periodic: a cylinder is two half-faces, a sphere two hemispheres. Every
  face's UV domain is a plain box with no wrap, so every 2D algorithm works unchanged
  (§5.4, decision D7).
- Approximate where there is no closed form (general surface intersections, their
  pcurves) and say so with a tolerance, rather than adding machinery to avoid it.

**DRY**
- One face-splitting engine (the UV map overlay, §7.3) serves sketch booleans, 3D boolean
  imprinting, plane sections and projection.
- One point-in-body classifier serves booleans, `contains?`, face classification and shell
  nesting. One evaluator dispatch serves everything that touches geometry.
- One checker is the oracle in tests, the `problem()` answer for hosts, and the debug
  assertion after every operation.

**YAGNI**: §1's non-goals, and within each milestone the "later/never" lists of §10.

**TDD**
- Every algorithm lands with its unit tests first, seeded from the books' worked examples
  (NURBS Book Ex 5.1 knot insertion, Ex 7.2 nine-point circle; BKOS's degenerate sweep
  inputs; Stroud's cube built five ways, S fig 4.1–4.5).
- Every operation's tests end with `check.all(body)` and the property suite (§9).
- A bug fix lands with the test that fails without it.

---

## 4. Package layout and dependencies

Locus is a Zig package with its own `build.zig` and `build.zig.zon`, kept as
`core/src/locus/` inside the KupCAD monorepo for now (one checkout, one CI, one place to
keep the adapter in sync) and consumed by `core/build.zig` as a path dependency
(`b.dependency("locus", .{})`). Extraction to its own repository is planned for later and
must need no code change, which is why the package boundary is drawn now. KupCAD's
adapter (`core/src/kernel/engines/brep/driver.zig`) stays in KupCAD; KupCAD continues to
import `locus.Resolution` for the shared curve-cutting rule.

Locus is pure Zig. The two C++ files go: the Levenberg–Marquardt solver, 3×3/4×4
determinants and the PCA normal are small Zig routines (Jacobi eigenvalues for a
symmetric 3×3 is ~60 lines); the exact predicates are a Zig port of Shewchuk's adaptive
`orient2d`/`incircle`/`orient3d`; `parallelFor` becomes a `Parallel` interface the host
implements (KupCAD's with oneTBB, the default serial). Removing Eigen and TBB from Locus
is what makes it buildable alone and for WebAssembly without flags.

C or C++ is not banned (Leo, 2026-11-06): a library may be linked when all three hold —
it gives the codebase more than writing the piece in Zig would, it costs nothing in
portability (KupCAD runs as a CLI, as a library and as WebAssembly, and Locus with it), and
it closes no door for the kernel's future. None of M0's pieces meets the first test: the
numerics are a few hundred lines, the exact predicates exist in no library we could link,
and threads are the host's to supply. A library that does meet all three is added as a
decision in §11 with the reasons, and stays behind the host (as oneTBB does, through
`Parallel`) wherever it is not pure in wasm.

**Targets**: native (Linux, macOS, Windows) and `wasm32` (KupCAD's browser and desktop
builds carry the B-Rep engine, STEP export included). On wasm there is no threading and
no file system: the host's `Parallel` is the serial default, every operation is a pure
function of its inputs, and nothing in Locus touches `std.fs`, `std.Thread` or the
environment. Workers in the browser can later implement `Parallel` without a change to
Locus. Memory is tighter on wasm32 (KupCAD runs scripts under a heap limit there):
operations allocate through the caller's allocator only, free intermediates as each phase
ends, and never hold a second copy of a body beyond the result. Locus's tests run under
wasmtime in CI as KupCAD's do.

```
locus/
  build.zig  build.zig.zon
  src/
    root.zig          public API: Body, Tolerance, Resolution, ops, results, check, io
    math/             vec.zig mat.zig predicates.zig (exact orient/incircle) solve.zig (Newton, LM, Jacobi)
    tolerance.zig     Tolerance, Resolution
    geometry/         types.zig curves.zig pcurves.zig surfaces.zig nurbs.zig arena.zig
    topology/         types.zig body.zig euler.zig traverse.zig check.zig tags.zig
    spatial/          aabb.zig grid.zig (hashed welding grid) bvh.zig (preorder flat)
    sketch/           region.zig overlay.zig offset.zig hull.zig contours.zig
    construct/        primitives.zig sweep.zig (extrude, revolve) loft.zig sew.zig
    intersect/        curve_surface.zig surface_surface.zig march.zig events.zig
    boolean/          pipeline.zig pave.zig imprint.zig classify.zig select.zig simplify.zig
    local/            offset.zig shell.zig chamfer.zig fillet.zig
    measure/          bbox.zig mass.zig genus.zig
    query/            point_in_body.zig raycast.zig distance.zig faces.zig
    mesh/             edges.zig triangulate.zig tessellate.zig
    io/               step_write.zig step_read.zig body_json.zig debug_obj.zig
    parallel.zig
  test/               corpus/ (named degenerate cases) fixtures/ bench/
  docs/               architecture.md README.md
```

Tests sit beside their sources as `*_test.zig` (the repository's convention) and are
registered in `root.zig`; `zig build test` in `locus/` runs them alone.

Allowed import direction, enforced by a layering test as KupCAD's `layering_test.zig`:
`math, tolerance` ← `geometry` ← `topology, spatial` ← `sketch, construct, intersect,
measure, query, mesh, io` ← `boolean, local` ← `root`. Nothing imports upward; `io` and
`check` import no operation (an operation may import `io` for its trace, §12).

### 4.1 The shape of every public function

Zig errors carry no payload, so every operation takes a `*Diagnostics` and returns an
error set: `fn boolean(allocator, a: *const Body, b: *const Body, op, options, diag:
*Diagnostics) Error!Body`. The error names the class (`InvalidInput`, `Degenerate`,
`NotRepresentable`, `TooSmallEdge`, `IntersectionFailed`, `NotValid`, `Canceled`,
`OutOfMemory`, …); `Diagnostics` holds the findings and warnings with their entities and
measured values. A host that ignores diagnostics still gets a precise error; one that
reads them gets the entity (KupCAD's error line can then name the face).

`Options` is per operation and always has `tolerance: ?Tolerance` (null: the bodies'),
`limits: Limits`, `cancel: ?*const std.atomic.Value(bool)`, `parallel: ?Parallel` and
`trace: ?Trace` (§12).
`Limits` bounds every iteration a bad input could lengthen: Newton trials, marching
steps, subdivision depth, curve-fit points, faces per body, entities per arena (KupCAD's
`max_newton_trials` and `max_marching_steps` come from here; the loops are bounded by
construction, the limits make the bounds explicit). The cancel flag is checked between
phases and every few hundred marching or sweep steps, and a cancelled operation returns
`error.Canceled` with its inputs untouched and nothing allocated; KupCAD's language
server cancels a preview on every keystroke and today has to kill the worker when the
mesh kernel cannot stop.

Inputs are validated at the boundary: finite numbers, positive sizes, `t0 < t1`, bodies
that pass the structural checker; a violation is `error.InvalidInput` with a message,
never an assertion (assertions are compiled out of release builds). Bodies are immutable
once returned, so they can be read from any thread; the allocator a host passes must be
thread-safe when it also passes a threaded `Parallel`. Because Locus allocates only
through the caller's allocator, KupCAD can hand it its counting allocator and, for the
first time, include the kernel's memory in the script's memory limit (Manifold's C++
allocations never counted).

Every public function's doc comment states what it assumes, what it returns, how it can
fail and roughly what it costs, in the plain style of KupCAD's own docs.

**Licensing.** The reference kernels are sources of ideas, not code: OCCT is LGPL,
SolveSpace GPL-3, SMLib proprietary, libfive MPL-2, SolidCraft MIT or Apache-2.0 (read for
its test apparatus and record rules, 2026-11-07). Nothing is copied from them. Shewchuk's
predicates are public domain and are ported; the books' algorithms are reimplemented from
their descriptions.

---

## 5. The model

### 5.1 Geometry

All geometry is parametric, in millimetres and radians, with STEP Part 42's
parameterizations so that export is a transliteration and import a lookup (usd-brep's
schema keeps the same convention). Right-handed, column vectors, counter-clockwise
positive; normals transform by the inverse transpose; a mirror flips `same_sense`.

| Kind | Form | Domain, period |
|---|---|---|
| Line | `o + t·d`, `d` unit | `t ∈ ℝ` (mm) |
| Circle | `c + r(cos θ·x + sin θ·y)` | `θ ∈ [0, 2π)`, periodic |
| Ellipse | `c + a cos θ·x + b sin θ·y` | periodic |
| NURBS curve | clamped, degree ≤ 9, rational via 4-D control points (A3.1, A4.2) | knot span |
| Plane | `o + u·x + v·y` | ℝ² |
| Cylinder | `o + r(cos u·x + sin u·y) + v·z` | `u` periodic |
| Cone | `o + (r + v sin α)(cos u·x + sin u·y) + v cos α·z` | `u` periodic; apex at `v = −r/sin α` |
| Sphere | `c + r(cos v cos u·x + cos v sin u·y + sin v·z)` | `u` periodic, `v ∈ [−π/2, π/2]`, poles |
| Torus | `c + (R + r cos v)(cos u·x + sin u·y) + r sin v·z` | both periodic |
| Linear extrusion | `C(u) + v·d` | `u` as `C`, `v ∈ ℝ` |
| Revolution | `rotate(C(v), axis, u)` | `u` periodic |
| NURBS surface | tensor product, clamped (A3.5, A4.4) | knot box |

Parabola and hyperbola arcs (a plane cutting a cone) are stored as exact rational
quadratic NURBS (NURBS Book ch. 7: every conic arc is one), so the curve set stays small.

The parametric contract every kind implements: `domain()`, `periodic()`, `eval(t)`,
`d1(t)`, `d2(t)` (surfaces: `eval(u,v)`, `du, dv, duu, duv, dvv`, `normal`), `project(p,
seed) → param` (closed form for lines, circles, planes, cylinders, cones, spheres, tori;
Newton with the NURBS Book's four stopping tests, §6.1, for the rest, seeded by a coarse
sample), `bounds(interval) → AABB` (convex hull per span for NURBS, P3.5), and
`toNurbs()` for STEP fallback and parity tests (A7.1 circles, ch. 8 extrusion, A8.1
revolution).

NURBS code is the catalogue's "implement first" set: A2.1 FindSpan (with the `u = u_m`
rule), A2.2 BasisFuns (division-free), A2.3 DersBasisFuns, A3.1/3.2/3.5/3.6, A4.2/A4.4
rational derivatives by Leibniz, A5.1/5.3 knot insertion, A5.4/5.5 refinement, A5.6/5.7
Bézier decomposition, A7.1, A8.1, §6.1 projection, §6.5 reversal. Knots are stored as
distinct values plus multiplicities (Farin §10.8). Later: A5.8 removal (with the negative
weight check), A5.9 elevation, ch. 9 fitting, ch. 10 skinning and sweeps.

Pcurves (a coedge's image in its face's UV box) are stored explicitly for every coedge of a
face on a non-planar surface and computed on the fly on planes. They are exact where a
closed form exists (a line on a cylinder is a line in UV; a cap circle is a horizontal
line) and otherwise an approximating 2D NURBS within the `approx` tolerance, flagged. The
3D edge curve is the truth; pcurves order and triangulate (usd-brep proposal, "Trimming
curves"; OCCT's pcurve approximation). The checker verifies each pcurve lifts onto its
edge within tolerance.

The geometry arena interns points, lines and planes through a hashed grid with cell size
≥ 2·zone, welding to the first kept entry (RTCD pp. 466–474), replacing the linear scans.
Surfaces are interned too, by canonical form where one is cheap (a plane by its normal
and offset, a cylinder by axis line and radius) and by tolerance comparison otherwise, so
that "these two faces lie on the same surface" is an index compare in the boolean and in
`simplify` (OCCT's `UnifySameDomain` has to recover this by comparing geometry).

### 5.2 Topology

Manifold B-Rep in the loop-edge-link ("half-edge") form that Stroud (S p.38, 44, App. A)
and Hoffmann both expect, with an explicit edge record, and a body that owns its arenas.

```
Vertex  { point: PointIndex, gap: f64, coedge: CoedgeIndex /* one leaving it */, tag }
Edge    { curve: CurveRef, t0, t1: f64, start, end: VertexIndex, gap: f64,
          coedge: CoedgeIndex /* first of its two */, flags: {degenerate, seam, approx},
          regularity: {c0, g1, g2} /* how its two faces meet */, tag }
Coedge  { edge: EdgeIndex, same_sense: bool, partner: CoedgeIndex /* NULL on a sheet edge */,
          next, prev: CoedgeIndex, loop: LoopIndex, pcurve: PCurveRef /* NULL on planes */ }
Loop    { face: FaceIndex, first: CoedgeIndex, next_in_face: LoopIndex }   // first loop = outer
Face    { surface: SurfaceRef, same_sense: bool, first_loop: LoopIndex, shell: ShellIndex,
          next_in_shell: FaceIndex, uv_box: [2][2]f64, flags, tag, attribute: u32 }
Shell   { first_face: FaceIndex, next_in_body: ShellIndex, kind: {outer, void, sheet} }
Body    { tol: Tolerance, shells: first ShellIndex, arenas…, bbox cache }
```

Orientation conventions (fixed once): a face's outward normal is the surface normal when
`same_sense`; the outer loop runs counter-clockwise seen from outside (face to the left of
each coedge), hole loops clockwise (BKOS p.30); a coedge with `same_sense` traverses its
edge from `t0` to `t1`; the two coedges of an edge are opposite (`partner.same_sense !=
same_sense`), which the checker enforces as the manifold condition.

A `Body` is a value: one outer shell, optional void shells, or one open sheet (a sketch
is a body of planar faces on `z = 0`; `Body.kind` is `solid` or `sheet`). A body with no
shells is the **empty body**, valid, with zero measures and an empty mesh: a union of
nothing, an intersection of disjoint parts, a difference that removes everything.
Operations take bodies by `const` reference and return a new body; inputs are never
touched (KupCAD's single-owner rule, and the opposite of SMLib's consuming booleans).
`Checkpoint` rolls back a body under construction.

`regularity` on an edge records how its two faces meet: `c0` (a real crease), `g1`
(tangent planes agree: a seam split, a fillet's boundary, a cylinder meeting its tangent
plane) or `g2`. Fillet chains (§7.8) follow `g1` edges; the viewer draws only `c0` edges
as feature lines; `simplify` never merges across `c0`. The two half-faces of a split
periodic surface carry the **same tag**, so a selection of "the cylindrical face" by name
finds both halves and a tag never distinguishes an artefact of D7.

Degenerate edges: a sphere's pole, a cone's apex and a revolved profile's point on the
axis are edges whose 3D curve is a point (`start == end`, `flags.degenerate`) but whose
pcurve is a UV segment, exactly OCCT's and SMLib's "degenerated edge". A vertex must sit
at every singular point of a curve (H p.195). Kill-edge refuses to remove a degenerate or
seam edge (S p.746).

Each entity carries a `tag` (§8): the operation and source entity it came from, copied on
split, unioned on merge, so KupCAD's `named`/`on_face` selections and future fillets can
find "the same face" after a parameter changes (S p.42, 262–270).

### 5.3 Euler operators

The spanning set plus Stroud's practical variants, each a pure topological core taking
coedge indices, with geometry assigned by the caller (S p.92, 722; "layered set"):
`mvfs/kvfs` (the only legal first operation), `mev` (spur, split-edge and split-vertex
forms), `mef`, `kef`, `kev`, `kemr` and its inverse `mekr`, `kfmrh/mfkrh` (a face becomes a
hole loop of another, raising genus or merging shells), `mvh/kvh` (isolated vertex loop),
`slice_edge` (a two-edge face, for sections), `merge_vertices`, and the null operators
that only relink. After each, in Debug and tests, the structural checker runs; each
operator has an `op ∘ inverse = identity` property test.

### 5.4 Faces without periodicity (decision D7)

Periodic surfaces are covered by faces whose UV boxes do not wrap: a cylinder is two
half-faces split at `u = 0` and `u = π`, a sphere two hemispheres with degenerate pole
edges, a torus four quarter-faces. The alternative, one face per surface with a seam edge
used twice by the same face, is what OCCT, SMLib and Stroud do (S p.41) and is the source
of a disproportionate share of their defects (usd-brep `KNOWN_ISSUES.md` lists six
seam/pole mis-repairs; "the missing seam" is a healer stage). SolveSpace never has
periodic faces and never needs seam logic. The cost is a few more faces and a rule for
`simplify`: never merge two faces across an edge when the merge would make the face
periodic. STEP readers accept either form.

---

## 6. Tolerance and robustness

**One tolerance per body**, SMLib's scheme (usd-brep `SmTol.h`): `zone` is the radius of
every vertex's and edge's tolerant neighbourhood; `xsect = 2·zone` is the distance at
which two things are taken to meet and the least distance at which two points are
distinct; `approx = zone/2` bounds every approximation (pcurves, marched curves, NURBS
fallbacks); `angle = 1e-4` (as `1 − cos`) compares directions and never scales;
`param` is a relative parametric tolerance. `zone` comes from the host (KupCAD's
`tolerance`, 1e-5) or, when the host gives none, from the body's size by SMLib's decade
table (1e-5 for 1–100 mm, 1e-4 for 100–10 000, …). A boolean of two bodies uses the
larger `zone`.

Per-vertex and per-edge `gap` record how far a construction missed (an approximated curve's
deviation, a welded vertex's move). They are written by constructions and read by the
checker; nothing grows a tolerance silently to make a check pass (SMLib's 1.0.1 bug: an
edge given tolerance 16 broke the next boolean). A result whose gaps exceed `zone` is an
error with the entity and the measured value. OCCT's invariant `gap(vertex) ≥ gap(edge)
≥ gap(face)` holds by construction: a vertex's ball encloses the ends of its edges' balls,
which enclose their faces' (`BRepLib::UpdateTolerances`). The part of an edge outside its
two vertex balls is its *shrunk range*; an edge whose shrunk range is shorter than `2·xsect`
cannot be split and is reported (`TooSmallEdge`) rather than cut (OCCT
`IntTools_ShrunkRange`).

**Two tiers of numeric decision** (RTCD ch. 11, BKOS ch. 2 and 9):
1. Combinatorial decisions in 2D — the order of edges around a vertex in the overlay,
   which side of an edge a point is, whether a flip is legal — use the exact adaptive
   predicates `orient2d` and `incircle` on `f64` coordinates. They never disagree with
   themselves, so a sweep cannot loop and an arrangement cannot be inconsistent.
2. Classification against 3D geometry — point on plane, coincident surfaces, welding —
   uses absolute tolerances in model units with "thick" surfaces (RTCD pp. 444–446),
   never relative epsilons as a general equality. Constructed points are welded at once
   so every later decision sees one coordinate per point (RTCD p. 474).

**Incidence is decided once** (H p.81–82, 117): every face pair of a boolean is analysed
one time and the result posted to both bodies; the "mark A on B, then B on A" symmetric
design is not used because the two passes can disagree. Decisions test against surfaces
and input data, not against derived curves (S p.751). A minimum feature size `δ > 2·zone`
is enforced: edges shorter than it are collapsed by `merge_vertices` at the end of an
operation (H p.117–118).

**Determinism**: every module sets `@setFloatMode(.strict)`; no fused multiply-add in
anything that decides topology; transcendental functions (`sin`, `cos`, `atan2`) appear
only in constructions, whose results are welded; every loop iterates arena indices, never
hash-map order; parallel work is merged in index order. A test builds each example twice
and with `Parallel` serial and threaded and compares the serialized bodies byte for byte
(as KupCAD's `determinism_test.zig` does for Manifold).

Arcs in the 2D overlay are where the exact tier is thinnest (an arc–arc or line–arc
intersection is irrational). Arc endpoints and intersection points are constructed,
welded and then treated as exact vertices; the order of half-edges about a vertex is
decided by `orient2d` on points sampled a hundred zones along each curve, and nesting by
the exact ray rule. Every decision about a circle is exact too (D26, 2026-11-11): whether a
line meets, touches or misses a circle and where each crossing lies along the segment
(`lineCircleDiscriminant`, `lineCircleCrossing`), whether a point lies within an arc's turn
about its centre (`orient2d` about the centre, never an angle: no seam, no slack, and the
same answer for a vertex a little off the circle whichever piece of the arc asks), which
of two crossings the nesting ray meets first (`compareArcX`, `compareArcXWithLine`,
`compareLineX`, a point taken as a circle of no radius), and a tie there means one point,
where the two segments meet: their order is the one at the end they share, the segment
leaning east going up when they fan up from a vertex on or below the ray (the ray taken
a hair above it), going down when they fan down from a vertex the welder put a rounding
above it where their circles cross at its height (two level there and opposite, the
lowest points of two arcs rising each way, lean as far as they can: the east one), then
of two tangent the same way the one bending east. Each such expression has bounded depth and `f64` leaves, so squaring
removes the roots and Shewchuk expansions evaluate the polynomial
(`backups/locus-plan/research/li-chen-egc.md` §2). What exactness cannot do is put an
arc's welded ends on its circle; those reconciliations (an arc piece within the zone of its
chord is its chord, every vertex within the zone of an edge cuts it, the pieces cut again
until a pass cuts nothing) are the welding's, not the predicates'.

---

## 7. Operations

Every operation is a pipeline whose phases are separate functions with table inputs and
outputs, each testable alone, and whose intermediate bodies pass the structural checker.

### 7.1 Construction

- Primitives build faces explicitly with analytic surfaces and exact edges: box (6 planes),
  cylinder and cone (two half-faces, two planar caps, or a degenerate apex edge), sphere
  (two hemispheres, two pole edges), torus (four faces), from `sew` of a closed set of
  faces whose shared edges are matched by vertex pair and curve (today's `twin_map`
  generalised).
- Extrude and revolve share one *generator × director* table (OCCT `BRepSweep`): a
  generator vertex swept along a director edge makes an edge, a generator edge a face, a
  generator face a solid; a generator face at a director vertex makes a cap. The surface
  of each swept edge is chosen by kind: a line along a vector gives a plane, an arc a
  cylinder, any other curve a linear-extrusion surface; around an axis a line parallel to
  it gives a cylinder, oblique a cone, an arc a torus or sphere, any other curve a
  revolution surface; a generator vertex on the axis gives a degenerate edge and no face.
  The topology is the Euler sequence `mev; (mev, mef)*; mef` (S p.144).
- Revolve builds in one step from exact periodic surfaces, split at the seam per D7; a
  partial angle adds two planar end faces; a full turn is closed by exact face matching,
  never by stepping around the circle (S p.142, 758).
- Loft and sweep along a path (later): NURBS skinning (A10, §10.3) and the exact
  translational sweep (10.17); the general sweep is approximated by skinning placed
  profiles with the projection-normal frame (A10.1).

### 7.2 Intersection

`intersect.surface_surface(a, b, tol) → []IntersectionCurve` dispatches on the pair of
kinds. Exact where possible: plane∩plane (line), plane∩cylinder (two lines, a circle, an
ellipse), plane∩cone (conic), plane∩sphere (circle), sphere∩sphere (circle), coaxial
cylinders/cones/spheres (circles), equal-radius cylinders with intersecting axes (two
ellipses). Coincident and tangent pairs are detected before anything else (same surface
within `zone` → the faces are co-surface and handled by imprinting; tangent contact → the
touching point or curve is recorded as a vertex or edge). Everything else — plane∩torus,
cylinder∩cylinder in general, anything with a NURBS surface — is traced by marching with
Newton refinement onto both surfaces (H p.208–216, HB ch. 25.5: start points from the
faces' boundary curves, turning points and collinear-normal points so no closed loop is
missed) and stored as a NURBS curve fitted within `approx`, flagged `approx`. Curve∩surface
is closed form for lines against quadrics and planes, and subdivision plus Newton (Farin
§4.6, de Boor's sign-change root isolation) for the rest.

### 7.3 Face splitting: the overlay engine

`imprint(face, curves_in_uv) → new faces` computes the arrangement of the face's loops
with the given pcurves in the face's UV box by map overlay (BKOS §2.3–2.4): split at
intersections and at every vertex within the zone of an edge, then split the pieces again
until a pass splits nothing (a split at a vertex moves an edge's piece within the zone,
which near a tangency moves its crossings by up to `√(2·r·zone)`; the nightly fuzzer
2026-11-10), splice the half-edges into the cyclic order around each vertex with
`orient2d`, collect cycles, classify each by its leftmost-lowest vertex, link holes to
containers, label the resulting regions. The output is new loops and faces on the same
surface sharing edges exactly where the input curves lay. It is the only place faces are
split, and it serves:

- sketch booleans and offsets (the plane is the UV box),
- 3D booleans (intersection curves imprinted on both faces),
- plane sections (the plane's trace imprinted, then the section faces built; S p.187–192),
- projection (silhouette and boundary edges imprinted on a plane; S p.192–194).

As built for plane sections (`boolean/section.zig`, KupCAD's `slice`, 2026-11-12). The
plane's trace on each face's surface comes in closed form from `intersect/surface_surface.zig`
(a plane cuts a plane in a line, a cylinder in a circle, two lines or an ellipse, a cone along
its axis, a sphere and a torus along its axis in circles; a plane only touching a surface is
`tangent`; the rest waits for M5), and each edge's crossings with the plane from
`intersect/curve_surface.zig`, computed once per edge so both faces of an edge split their
traces at the same points. The imprint on a face is the trace split at the face's boundary
points and each piece kept when its middle is inside the face; the face itself is not split,
since a section needs only the pieces (M4's `trim_by_plane` splits it with the same pieces).
Each kept piece runs along `n_plane × n_face`, the material on its left, and the pieces are
one input of the overlay, whose faces wound once are the section, a sheet on `z = 0`. On the
plane the section is the solid just above it, as Manifold slices (a triangle counts when its
lowest corner is at or below the height and its highest above): a face lying in the plane
gives nothing and an edge lying in it is taken from each face that rises from it, so two
faces rising from one edge (a groove's floor) cancel; a face only touching the plane gives
nothing. A trace that is an ellipse has no sketch edge and is refused naming the face.

### 7.4 Booleans

Inputs `a`, `b`, op ∈ {union, difference, intersection}. Stroud's stepwise algorithm with
Hoffmann's once-only incidence rule and OCCT's "paves" vocabulary:

0. **Reject**: AABB of bodies, then face pairs through the BVH (leaf boxes inflated by
   `zone`). No overlap → the containment table (A in B, B in A, disjoint) answers without
   geometry (S p.137–139).
1. **Interfere in dimension order** (OCCT `BOPAlgo_PaveFiller`): vertex–vertex, then
   vertex–edge, edge–edge, vertex–face, edge–face, each within the candidate pairs. Two
   things interfere when their distance is at most the sum of their gaps plus `xsect`.
   Coincident vertices merge into one with the enclosing ball; a vertex on an edge or an
   edge crossing an edge splits the edge there (`mev` split form) on its shrunk range;
   collinear overlaps become *common blocks* (one edge record shared by both bodies).
   Vertices whose gap grew are re-run through the lower stages once. This catches every
   touching and coincident configuration before any curve is computed.
2. **Face–face** (§7.2) on the remaining pairs gives intersection curves with pcurves on
   both faces. A curve's ends snap to the vertices of stage 1; a section edge is created
   only where no existing edge already covers that piece of the curve (OCCT's rule;
   SolveSpace's `EDGE_PARALLEL`). Coincident faces produce no curve: they are marked
   same-domain and handled in step 4.
3. **Imprint** the section edges on both faces (§7.3). The same edge record is used by
   both bodies' coedges, so the seam is already stitched; loops are walked by taking, at
   each vertex, the outgoing edge with the smallest clockwise angle in UV.
4. **Classify** each face fragment once as in / out / on-same / on-opposite the other body,
   by one interior sample point through the point-in-body classifier: a ray along the
   fragment's normal, the nearest hit strictly inside a face decides, a hit on an edge or
   vertex or a tangent face retries with the next direction from a fixed table (never a
   random one: determinism), a bounded number of times (H p.76–80; OCCT
   `BRepClass3d_SClassifier`; SolveSpace's six-direction table). Same-domain faces (same interned surface,
   equal edge sets after imprinting) are decided by normal agreement, never by sampling.
5. **Select** by Mäntylä's table (S p.137): union = A out ∪ B out ∪ on-same; difference =
   A out ∪ (B in, flipped) ∪ on-opposite; intersection = A in ∪ B in ∪ on-same. The
   general form, OCCT's General Fuse (compute every cell once, then any operation is set
   algebra on cells, and a fused face survives when it bounds one cell or two with the
   same orientation), is the planned route for N-ary batches once the two-body pipeline
   is solid.
6. **Assemble**: faces into shells by connectivity, choosing at a shared edge the next face
   by dihedral angle; orient consistently from the kept faces' `same_sense`; classify
   shells as outer or void by the point at infinity and nest voids into the nearest outer
   shell; a non-manifold edge (four coedges) becomes two edges in two shells (S
   p.126–127).
7. **Simplify**: merge faces on the same surface across edges that are now interior
   (coplanar annihilation and its curved analogue), subject to D7; remove vertices of
   valence two on a single curve; collapse edges below `δ`; `compact()`.
8. **Check** (§9): the result must pass every rule or the operation fails with the finding.

Batch unions and differences (KupCAD's chains) run as a sequence; a disjoint union is a
multi-shell body, an empty intersection an empty body (not an error). Materials and tags
flow through step 3 (copied) and 7 (unioned).

### 7.5 The 2D kernel (sketches)

A sketch is a body of planar faces on `z = 0`, bounded by lines and circular arcs (conics
in M5, beside the intersector that makes them, then NURBS), so it reuses the topology, the
overlay engine and the checker. Until then a section whose trace is a conic is refused,
never chorded into a polygon (NOTES §8). Sketch booleans are
the overlay with winding labels; offset is the sheet united with (grown) or less (shrunk)
the band its boundary sweeps, each edge's sweep (a rectangle, an annular sector, the pies
about a centre the offset passes) and each opening corner's join (round, miter, bevel,
square) a simple region the overlay counts as a second input (D25); hull is the convex hull of all vertices and arc extreme points as a polygon (arcs
are left out of the hull's boundary; documented, and the driver refuses a sketch with arcs
as `curved_hull`, D24, until the hull keeps its arcs); `query.contours` outputs closed polylines at a
`Resolution` (the mesh engine's polygon: lofts, sweeps) and `query.outlines` the same loops with
their arcs exact (`OutlineArc`: centre, radius, way round, sweep from the edge's range), what the
drawing exporters write as SVG arcs and DXF bulges with no chord matching; measures (area by
Green's theorem on lines and arcs) are exact.

### 7.6 Measures and queries

Bounding box from edge extremes (closed form for circles and ellipses, convex hull for
NURBS) and surface extremes within each face's UV box. Volume and area by the divergence
theorem integrated over each face's UV domain with Gauss quadrature on the tessellation's
UV triangles (independent of the viewer's resolution, with an error estimate); closed forms
for planar-bounded analytic faces later. Genus from `V − E + F − (L − F) = 2(S − G)` per
shell. `contains?` is the point-in-body classifier; `ray_cast` intersects the ray with
each face's surface (closed form for quadrics) and keeps hits inside the face's loops;
`min_gap` is a BVH-guided closest-point search over face pairs; `faces(direction, tol)`
returns faces by normal and centroid with their tags.

As built (`query/`, 2026-11-11). `index.zig`: each live face's box grown by the zone and a
BVH over them, built once per body and kept by the host beside its mesh (the driver's
`BrepSolid.index`); `Bvh.querySegment` descends it by slab tests. `in_face.zig`, the one
primitive every query stands on: a point of a face's surface is on the face's boundary
when within the zone of an edge (in space, on the exact curves: `nearestOnEdge`), else
inside when the face's loops wind about its UV, the winding being the angle each coedge's
image sweeps about the point (its pcurve; on a plane its curve projected; on a curved face
without one its curve projected onto the surface), a piece halved until it subtends under
a quarter radian and its halves agree, so no polyline of the boundary stands in for it and
lines, circles, ellipses and NURBS are one case; periodic parameters are moved by whole
periods into the face's box. `raycast.zig`: the candidates are the meetings of the line
with every face's surface whose box the segment meets, in closed form for planes,
cylinders, cones, spheres and tori (`math/poly.zig`: the roots of the implicit equation
along the line, degree 1, 2 or 4, by derivative isolation and bisection, the parameter
measured from the line's point nearest the centre, axis or apex so the coefficients
don't cancel; a critical point within the zone of the surface is a tangency), by
Levenberg–Marquardt and then Newton on `S(u, v) = O + t·d` from a 16 × 16 grid of seeds for
extrusion, revolution and NURBS surfaces (sampled: a grazing pair between seeds may be
missed); kept when in the face or on its boundary. Candidates within the zone of one
another are one place; a place that is one candidate strictly inside its face, not
tangent, crosses by the sign of its normal; any other (edge, vertex, tangency) is decided
by classifying the points halfway to its neighbours, the difference being the crossing, no
difference a touch reported as an entry and an exit at one distance (as the mesh engine
reports a grazed corner). `point_in_body.zig`: outside the body's box is outside; within the
zone of a face (its foot in the face) or of an edge is the boundary; else a ray from the
point to its foot on one of the six nearest faces (along that face's normal, met squarely),
then along a table of twelve skewed directions, the nearest meeting deciding when it is
clean, a ray meeting nothing being outside, and a refusal with a finding when every ray met
an edge or a tangency first. `distance.zig`: branch and bound over the two meshes'
triangle BVHs (RTCD's triangle and segment distances) keeps every face pair within the
meshes' deviation (twice `chordBow` of the longest triangle side, per mesh) of the
nearest, and each is polished on the exact faces by alternating projection (a face's
nearest point is its surface's foot when that is in the face, else its edges' nearest),
so the gap is the exact geometry's; within the zone it is 0. `faces.zig`: the planar faces
facing a direction within `tol.angle`, farthest first, each with its exact area and area
centroid by Green's theorem over its loops (Gauss–Legendre per edge) and its tag; the
driver merges the faces at the farthest plane into one handle, as the mesh engine does.
The fuzz chains cast vertical and horizontal rays at every extruded solid: the running
count of crossings stays 0 or 1 and ends 0, and at the ray's midpoint it is the
midpoint's containment.

### 7.7 Tessellation

Edges first (SMLib `SmTess`, SolveSpace `triangulate.cpp`, OCCT `BRepMesh`): every edge is
discretized once by `Resolution` (segments per circle, or angle and length limits; a
circle's step is `min(2·acos(1 − d/R), angle)` for chord height `d`) and, for a curve on
two curved faces, by the finer of the two, so adjacent faces share identical boundary
points and the mesh is watertight by construction. A circle of radius `r` is cut into
exactly `Resolution.segmentsFor(r)` equal segments starting at angle 0, and an arc into
the segments of that same grid it covers, rounded outward: the very polygon KupCAD's mesh
engine builds for the same circle. That is the kernel-parity rule (every parameter means
the same on both engines): a cylinder tessellated by Locus has the vertices Manifold's
cylinder has, so the parity tests' bounding boxes and the viewer's picture agree. Two arcs
tangent at a vertex and curving the same way bound a cusp, where chords of the two cross
however fine the grids (the flatter arc's chord dips under the tighter arc); there the
flatter arc also takes a point at each tangent coordinate the tighter arc's points have
(`edges.matchCusps`, 2026-11-11), so both polylines interpolate ordered depths and cannot
cross. A sketch arc across its circle's seam is two edges from the start (§7.5, D7).

Per face: the loops' pcurves, evaluated at the edge points' parameters, become a
UV polygon with holes (a plane's by projection; a degenerate edge, a pole or an apex, its
pcurve's start, so the ring runs along the pole line), scaled to be near-isometric by the
surface's derivative lengths at the middle of its UV box (on a cylinder `u` is radians and
`v` millimetres; without the scaling every triangle is a sliver); triangulated by monotone
partition (BKOS ch. 3, deterministic, holes native), then Lawson flips to a constrained
Delaunay (Lemma 9.4, exact `incircle`, boundary edges never flipped). A curved face
(cylinder, cone, sphere, torus; 2026-11-11) then gets interior points: the tensor grid of
its boundary's distinct `u` and `v` values and of the resolution's own parameter lines
around each circular direction (the grid a full circle of that direction's largest radius
gets, from angle 0: the edges' own grid, so a boundary along a circle adds no line), each
candidate inside the polygon and no nearer a ring's edge than a merge tolerance (two edges'
ends agree only to rounding: a seam's end parameter against a circle's pcurve height put
candidates two ulps inside the frustum's top edge, as slivers), inserted into the CDT
(BKOS §9.3: a point in a triangle splits it in three, on a side both triangles in two,
then Lawson flips) and mapped through the surface; a triangle with two corners at one
mesh vertex (along a pole line) is dropped. A cylinder's side gets no interior point and
has the mesh engine's vertices; a hemisphere a latitude-longitude grid with pole fans; a
cone's side a fan to its apex. A free-form edge (an ellipse, a NURBS curve) is cut where
its **certified chords** say (`mesh/chords.zig`, 2026-11-11): a span passes when an
enclosure of it, in a frame along its chord, reaches no farther across the chord than
`Resolution.chordBow(L)`, the sagitta a circle's segment with that chord has at the
resolution (`(L/2)·tan(θ/4)` for the turning `θ` of `min_angle`, or of the coarsest
circle, `2π/MIN_AUTO_SEGMENTS`, when the chord is within `min_length`: the coarser of the
two rules, as a circle is cut), and no farther past either end; else it is halved, the
halves' ends the samples, `MAX_DEPTH` halvings at most and then a refusal with the
finding (a cusp, a loop smaller than the budget). The enclosure of an ellipse's span is
interval arithmetic in the mean-value form (`(P(t) − P(a))·n = (t − a)·P'(ξ)·n`, the
plain form cannot see the cancellation along the chord and never shrinks under the
budget); a NURBS span's is the hull of the Bézier control points of that piece (A5.6,
then de Casteljau), measured on the piece's two halves (an arc's apex control point stands
twice its sagitta off the chord, the halves' once). Every test leaves room for rounding:
the budget less three times an a-priori bound on a point's evaluation error
(`evalRounding`), so a curve too ill-conditioned to certify (weights decades apart) is
refused, not certified by luck (fuzz find, 2026-11-12). A free-form face (an extrusion or a
revolution of such a curve, a NURBS patch) gets the generator's certified chords and the
patch's knots as its grid lines (a revolution's `u` the circle grid of its farthest
radius), then is refined where a link's or a triangle's midpoint on the surface stands
off the mesh by more than `chordBow` of its length, `MAX_REFINE_ROUNDS` times at most: the
face test is sampled, the edge certificate is not. Output:
positions, normals, triangles (`f64` inside Locus; the adapter narrows to KupCAD's
`f32`), per-face triangle ranges so KupCAD can colour parts and map a hovered triangle to
its face, **per-edge polylines with the edge's id and regularity** (`Mesh.edges`,
`edge_vertices`) so the viewer can draw the model's true edges (today it infers feature
edges from mesh dihedral angles and misses or invents some) and none of the `g1` ones (the
KupCAD protocol does not carry them yet), and a status per face with why: a face that
fails to triangulate is reported `.failed` with the finding's code, filled leniently (a fan
of its outer loop, so the picture has no hole), and the rest of the mesh is still
delivered (a viewer wants the part it can draw; a boolean, by contrast, fails whole).
Tests assert `CHECK_EDGE_PAIRS` (every edge once forward and once backward), exact
counts for a box, a cylinder, a cone and a torus, outward normals on a sphere, no
degenerate triangles, and the mesh's volume and area against the exact ones within the
chords' share; an elliptic extrusion, a rational-arc extrusion, a spline revolution and
a bilinear saddle the same; the fuzz chains extrude their sheet and hold its mesh to the
same, and a fuzz target shapes random ellipses and NURBS curves and checks each certified
chord densely. The driver's `getMesh` and `numTris` build the mesh at the part's
resolution (`supports(.mesh)` since 2026-11-11), once per part and kept (a body never
changes); a free-form edge no chord certifies refuses the whole mesh, so no export writes
a hole. **A bounded provisional mesh** for the viewer while a part is being edited
(research/solidcraft.md §2, 2026-11-11): `tessellateWithin(body, resolution, Budget)`
caps the interior points per edge (resampled evenly at the cap), per face (the grid
thinned, refinement stopped) and per body (the edges' total, then the faces' share of
what is left), and marks the mesh `provisional` when a cap cut it; a part within the
budget gets its full mesh, unmarked. The driver's `getPreviewMesh` serves the viewer
(`kernel.getPreviewMesh`, the preview frame's GLB): the part's own mesh when it has been
built, else one under `PREVIEW_BUDGET` (32 points per edge, 4096 per face, 2¹⁸ per body),
kept as the part's mesh when whole and as its preview when cut, so a large exact part is a
bounded picture at once rather than a late one (a cache miss, never a late picture); the
frame says `provisional: true` for such a part, and an export always builds the full
mesh. A capped mesh is a picture, not a measure: never exported, never certified.

### 7.8 Local operations (later)

Offsets of planes, cylinders, cones, spheres and tori are exact (move the defining point
or radius; S App. D.12); a solid offset is the offset of every face, re-intersected at the
edges, with convex edges joined by cylinders/spheres (rolling ball) and concave ones by
intersection; shell = body minus its inward offset as a void shell (S p.115).

Fillets and chamfers are built in phases, each a usable release, on one option structure
designed for all of them from the start. The options follow SMLib's four independent
axes (usd-brep `SmApiFillets.h`): the **radius law** (constant; constant distance = a
chamfer; variable), the **cross-section** (circular; later linear or a blend), the
**continuity** (G1; later G2) and the **corner strategy** (round; later bevel). Phase 1
implements one point on each axis and leaves the others as enum values that return
`error.NotImplemented` with the phase that will add them.

- *Phase 1, single convex edge, constant radius*: Stroud's rebate recipe (S p.246–250):
  offset the two adjacent surfaces by `r`, intersect them for the spine of the rolling
  ball, cut the adjacent faces back to the tangency lines, and insert the blend face; where
  the adjacent faces are planes and cylinders the blend surface is exactly a cylinder, a
  torus or a sphere (OCCT `ChFi3d` takes the same exact cases first), otherwise a rolling-
  ball march in `(u1, v1, u2, v2)` with `P1 + r·n1 = P2 + r·n2` (OCCT) fitted within
  `approx`. Ends of the edge meet the neighbouring faces by a straight cut. Refused: a
  radius below `8·zone` (SMLib's limit) or larger than the adjacent faces can take.
- *Phase 2, tangent propagation*: an edge selected for filleting extends along its chain
  of tangent-continuous neighbours (OCCT's *spine*), so a filleted box edge that turns
  into an arc is blended as one stripe.
- *Phase 3, corners*: where two or three filleted edges meet at a vertex, trim the stripes
  against each other and fill the corner with the exact patch when one exists (a sphere
  for three equal radii on a box corner, S p.248's eaves for vertices of more than three
  edges), else a small NURBS patch (F §19 G1 conditions, Coons fill).
- *Phase 4 and beyond*: variable radius along the spine, G2 cross-sections, bevel corners,
  vertex blends. Not scheduled; the option axes keep the door open.

Variable-radius and vertex blends are therefore a roadmap entry, not a non-goal.

### 7.9 Input and output

STEP AP214 writer for every geometry kind (the current writer plus cones, tori, ellipses,
B-spline curves and surfaces, extrusion and revolution surfaces, pcurves optional), one
`MANIFOLD_SOLID_BREP` per body, vertices and edges written once (SolveSpace's aliasing),
validated by KupCAD's `check:3mf`-style job with an external reader. Numbers are written
at full `f64` precision (the shortest text that reads back to the same double, Zig's
`{d}`), never rounded: the present writer prints radii with six decimals, which is a
0.1 µm error on every circle and makes a "lossless" export lossy. The file's
`UNCERTAINTY_MEASURE_WITH_UNIT` is the body's `zone`. The writer returns a **report**
beside the text (`writeReported`, 2026-11-09, research/opengeometry.md §2): the counts
of solids, shells, faces, edges, vertices, degenerate edges left out, B-spline curves and
surfaces, entities and bytes, and an exchange error bound (the largest recorded gap, plus
the frames' departure from orthonormal, plus 64 ulp of the largest coordinate), the same
counts and bound written into the file's `FILE_DESCRIPTION` so a reader can compare them
with what it finds (`check:step` does); the driver sends the report to the trace as the
export's one phase. STEP export is what KupCAD's users need first, on wasm too, and is
why the writer is in M1. A body JSON format
that is a straight dump of the arenas (usd-brep's `BrepArray` layout: per-table arrays,
counts, first-is-outer) replaces the fixture format and is the debugging snapshot. STEP
reading is scheduled only once the kernel is in good shape (after M7): it is the one place
a normalizer (weld vertices, drop degenerate faces, split seamed faces, insert pole
edges) runs, and it needs the booleans and checker mature enough to tell a bad import from
a kernel bug. A reader treats the file as hostile: every count, degree and index it reads
is bounded by `Limits` before any allocation (SMLib's unchecked degree fields were a
crash), and the reader is fuzzed like KupCAD's importers.

---

## 8. Attributes and naming

A `tag: u32` per face, edge and vertex indexes a side table `tags[]` of `{op: u32, source:
EntityRef}`; a boolean's new edge gets the pair of source face tags, a split face its
parent's tag, a merged face the union (S p.262–270). Each operation returns a change log
(entities added, removed, split from what) so a host can map selections across a rebuild —
the "bulletin board" (S p.262). Locus guarantees stability of tags, not of indices:
`compact()` renumbers freely. Materials are KupCAD's business; Locus stores a `u32`
attribute per face through the same mechanism.

As built (2026-11-12): `Face.attribute`, 0 for none, passive data Locus never reads (Stroud's
rule for it: copy on split, keep both on merge). It goes with the face wherever the face goes:
a clone or a move (the body copied index for index), a face's split (`mef`, and `mfkrh` making
a ring a face), a sweep (a sheet face's caps and sides take its attribute), the body JSON (a
file without the field reads as 0). M4's simplify merges two faces only when their attributes
agree, so a red face and a blue one on one plane stay two. KupCAD stores its material slot
there (`kernel.materialSlot`), and its driver writes the slot as each mesh vertex's fourth
property, a vertex shared by faces of different materials split into one per material, as
Manifold's meshes carry it.

---

## 9. Validity and testing

### 9.1 The checker

`check.run(body, level) → []Finding{rule, entity, measured, threshold}` is a pure function
(SMLib's `AssertValid` mutates caches; ours must not). Rules in order, stopping at the
first structural failure so geometric rules never read a corrupt graph (ACIS order, S
p.459–470):

*Structural*: every index in range; `next/prev` reciprocal; every loop closes with its
coedge count; coedge.loop agrees; `partner` reciprocal and opposite; an edge has one or two
coedges (two in a closed shell); a vertex's `coedge` leaves it; first loop of a face is the
outer one; each face in exactly one shell; shells connected; `V − E + F − (L − F) = 2(S −
G)` with `G` a whole number ≥ 0 per shell; flagged degenerate edges have `start == end`,
no other edge does.
*Orientation*: adjacent faces agree (the two coedges of each edge are opposite);
outer loops counter-clockwise and holes clockwise in UV; `same_sense` consistent with the
outward normal by one ray test per shell, and the cheap cross-check that the signed
volume (divergence theorem) is positive for an outer shell and negative for a void.
*Geometric*: vertex points on their edges' curves within `xsect`; edge curves on both
adjacent surfaces within `xsect`; pcurves lift onto their edges within `approx`, tested at
a fixed number of samples along the edge (OCCT uses 23); `t0 < t1` inside the curve's
domain; edge length > `δ`; face area > `zone²`; no two vertices within `zone` of each
other; UV boxes inside the surface domain without wrap; gaps ordered vertex ≥ edge ≥ face.
*Global* (slow, level 2): faces of a shell do not intersect except along shared edges
(the intersector run over face pairs); hole loops inside their outer loop and not inside
each other; the point at infinity is outside every outer shell; void shells inside the
outer shell and not inside each other; singular vertices of a solid (its faces about a
vertex not one fan, a solid touching itself at a point) as warnings; and OpenGeometry's two pcurve rules
(research/opengeometry.md §6, 2026-11-11): every coedge's pcurve, at nine parameters from
the edge's start to its end, lifts onto the edge's curve within `approx` and lies in its
face's UV box within the zone over the surface's metric there (`pcurve_outside_box`; no
slack limit where the metric vanishes, at a pole), and consecutive coedges of a loop join
in UV within that slack, a period apart counting as joined (`pcurves_disjoint`). The first
run of these rules over the primitives and a revolved stadium found `revolve` giving a
torus face a `v` range below the domain, and its two spans of one arc disagreeing on the
direction of `v` (the tangent of a turned copy against the profile's frame): the profile's
arcs are now split at the torus's seam first (D7) and the direction read from the
generator at angle 0.

From level 1 the report grades every shell in one vocabulary with the mesh validator
(`topology/condition.zig`, research/truck.md §2, 2026-11-11): `irregular` (an edge on more
than two faces, or none) < `regular` < `oriented` (the two uses of every shared edge run
opposite) < `closed` (every edge on exactly two faces), and beside it the singular
vertices, found over the whole body (two shells sharing a vertex record share it, which
neither alone can see) by grouping the coedges leaving each vertex into fans (a coedge and
the partner of the coedge before it, or that coedge itself when it is a degenerate pole or
apex edge) and charged to every shell using the vertex. `mesh/validate.zig` grades an
output mesh the same way by its indices (edge uses and directions, each vertex's link of
opposite sides one chain or not) and counts degenerate triangles; `CHECK_EDGE_PAIRS` is
`closed` with no singular vertex and nothing degenerate. (A lens thinner than its chords,
pruned from a ring as a spike, refines the face's arcs like a crossing does, since on a
solid its two sides would collapse onto one quad; `FaceRange.spikes_pruned` marks a face
still pruned past the doubling limit.) The edge findings name their
condition (`edge_coedge_count`: irregular; `partner_same_sense`: regular, not oriented;
`open_edge_in_closed_shell`: oriented, not closed).

One negative fixture per rule lives in `test/corpus/invalid/`.

### 9.2 Tests every operation carries

- **Properties**: result passes `check.run` at level 2; Euler–Poincaré per shell;
  `volume(A ∪ B) = volume(A) + volume(B) − volume(A ∩ B)`; `volume(A − B) + volume(A ∩ B)
  = volume(A)`; translation and rotation invariance of all measures; `op ∘ inverse` for
  Euler operators; a transform of a body is the body with transformed geometry and
  identical topology; tessellation edge pairs and watertightness.
- **Oracles**: analytic volumes and areas of primitives and their booleans (a cube minus
  a cylinder is `a³ − πr²h`); SolveSpace's pair of "no naked edges + analytic volume" per
  regression; OCCT's per-case triple of entity counts (vertices, edges, faces, shells),
  area and volume, and the largest gap in the result, so that tolerance creep fails a
  test before it fails a model.
- **Differential**: Locus's tessellation against Manifold through KupCAD's parity tests
  (same bounding box, volumes within the chordal error); brute-force reference for every
  accelerated routine (BVH vs. all pairs, grid weld vs. linear scan).
- **Degeneracy corpus** (`test/corpus/`): named configurations, each a test — cube in
  cube, touching faces (same and opposite normals), touching edges, touching vertices,
  coplanar overlap, equal-radius crossed cylinders, tangent cylinder–plane, coaxial
  cylinders, sphere through a pole, a boolean whose curve crosses a seam split, a cut
  exactly through a vertex, collinear overlapping sketch edges, cocircular points.
  SMLib keeps ~60 such surface-pair files; OCCT and SolveSpace fixed each of theirs after
  a bug report, so the list is seeded from their issue history.
- **Fuzz**: coverage-guided, as KupCAD's language is fuzzed (`std.testing.fuzz` with a
  `Smith` choosing the input, `zig build fuzz --fuzz=<runs>` searching from a corpus
  nightly, a plain test run replaying it): the body JSON reader and later the STEP reader
  on any bytes; the 2D kernel on generated rings of points on a coarse grid with
  operation chains (M2); random placements, rotations and scales of primitives combined
  by random booleans (M4). Every result is valid or a clean error, nothing leaks, the
  area and volume identities of booleans hold exactly, and no run hangs (every traversal
  is bounded by entity counts). A failing input is saved as a script, so it becomes a
  parity case.
- **Allocation failure**: every operation under KupCAD's failing-allocator sweep leaves
  nothing allocated and its inputs untouched.
- **Determinism**: §6.
- **Known issues**: `KNOWN_ISSUES.md` with an expected-failure test per entry, removed
  with the fix (usd-brep's process).

### 9.3 Parity with the mesh engine

KupCAD runs the same script on either engine (`CAD.config(engine: :brep)`), and the rule
is that **the script means the same on both**: the same options, the same results, the
same refusals. Locus cannot test this itself, since it knows nothing of KupCAD; the tests
live in KupCAD, in `core/src/kernel/parity_test.zig` and `invariants_test.zig`, and every
milestone extends them with the features it unlocks before its `supports` flag is flipped.

*Options.* Every parameter a method takes maps to one Locus input with the same meaning:
`segments` → `Resolution` (one implementation of the segment rule, Locus's, used by both
drivers, so both engines cut a circle into the same polygon, §7.7), `tolerance` →
`Tolerance.zone`, `center:`, positional and keyword forms, ranges. Defaults live in
KupCAD's `EngineConfig`, never in an engine. A parameter one engine cannot honour is
refused through a `Feature` flag with the "can't … yet" error, never ignored (an ignored
`segments` or `twist` is a stand-in result).

*Results.* Same bounding box. Locus's exact measures (volume, area, centroid, genus)
agree with Manifold's mesh measures within the bound that follows from `segments`, not a
loose epsilon: a circle of radius `r` cut into `n` segments has area `(n/2)·r²·sin(2π/n)`,
so a cylinder's volume deficit is known exactly and the test asserts it. Locus's own
tessellation at the same `Resolution` reproduces Manifold's mesh measures to floating
point, since the vertices are the same points. `decompose` gives the same number of parts,
`contours` the same polylines, names, materials and tags survive the same operations,
and an empty result is empty on both (`empty`: a boolean that removes everything never
raises on Manifold, so never on Locus).

*Refusals.* An argument one engine refuses, the other refuses with the same message (the
`REFUSED` table). Validation therefore lives in KupCAD's methods, before either driver.

*Properties.* The invariants suite (closed mesh, measures consistent with the mesh,
inclusion–exclusion, rigid moves keep volume, `scale(s)` multiplies it by `s³`) runs its
`SHAPES` on both engines; a property that holds on one and not the other is a bug. On the
B-Rep engine (`BREP_SHAPES`, since M3) the mesh's volume, area and box are held to Locus's
exact measures within the chords at 64 segments a turn (3ε, ε = 1 − sin θ/θ: a doubly
curved surface is a polygon revolved, its section's area, centroid and turn each ε short).

*Meshes compared* (M3, `kernel/mesh_compare.zig`, research/solidcraft.md §1): two closed
meshes without booleans, by the sampled symmetric distance (each surface sampled at its
corners and at most `spacing` apart, each sample's distance to the other surface through a
triangle tree) and the volume inside exactly one (lines along z over both, each triangle a
step in or out by its normal's side, the edge test computed from the edge's lesser end so
the two triangles of an edge get opposite values). The case rig compares the two engines'
meshes of every corpus case both build, both at 64 segments a turn: within the diagonal
times `1 − cos(π/64)` of each other, what only one holds within a shell of that thickness
over the surface.

*Allowed differences.* Two, and only two: exactness itself (Locus's circle is a circle,
Manifold's the polygon; the bound above is that difference) and what `supports` says is
missing. Where the mesh engine approximates by design (offset by shrink-then-grow,
curved hull as a polyhedron), the approximation is documented and the exact result is
allowed to differ by the documented amount. A third kind of difference is a bug on one
side; Locus is presumed right only once its oracle tests (§9.2) pass on the case.

*How the tests grow.* The `SHAPES` and `REFUSED` tables are the registry: M1 adds sphere,
cone, extrude, revolve and the measures; M2 the sketch operations and contours; M3 ray
casts, `contains_point`, `min_gap` and face queries with the same answers; M4–M5 the
booleans and the degeneracy corpus run on both engines; M6–M7 lofts, sweeps, offsets,
fillets. `kupcad dev brep-readiness` (§12) runs every example and documentation snippet on
both engines and compares box and volume within the chordal bound, so parity holds over
the whole corpus and not only the table. Today the parity test reads Locus's box from its
STEP export at `1e-5` (six decimals); with M0's full-precision writer that drops to
floating point, and with M1's `bounding_box` the box is read directly.

*The case rig.* Beside the tables, `tools/dev/cases.zig` is a rig of cases with their own
right answers (research: SolidCraft's kernel-cases): each a script, what it is, its
answer with the **formula in words** (`method`), where it came from (`from`: a plan item,
a fuzzer find, a report) and whether the answer is a closed form (`analytic`) or an
identity (`invariants`); the answer is never a kernel's output. Cases are ordered as a
**ladder** by tier (primitives, booleans, profiles, sweeps, holes, fillets, offsets,
patterns, cumulative parts), each tier on the shapes of the tiers before it. `case_rig.zig`
runs each case on an engine within a time limit and judges it: `pass`, `fail` (off its
answer, refused where a result was due, or built where a refusal was due, which says the
milestone landed and the case wants its closed form), `crash` (the host failed under it),
`hang` (past the limit), `refused` (by design, until the milestone the case names, counted
apart). A tier's **frontier** is its first case that fails, crashes or hangs; a case known
to fail is listed in `KNOWN_FRONTIER` with why, and the test holds the ladder to exactly
that list, so a regression and a fix that forgets the list both fail. On the B-Rep engine
the volume must match to 1e-9; on the mesh engine within the case's chordal bound. The
ladder with its frontier closes the `brep-readiness` report (§12). The first run found
the sweep case's own answer wrong (the profile's x rides the radius inward), the B-Rep
engine refusing to sweep an empty sketch where the mesh engine sweeps it to the empty
solid (fixed), and `cube(round_r:)` chorded on the exact engine (the known frontier).

---

## 10. Roadmap

Each milestone ends with its tests green, `check.run` level 2 on every fixture, the
parity and invariants tables extended with the scripts of the features it unlocks and
green on both engines (§9.3), the KupCAD `supports` flags flipped and the corresponding
`brepLacks` tests retargeted, and the docs updated. Line counts are estimates of the delta including tests.

| # | Milestone | Scope | Unlocks in KupCAD | ~lines |
|---|---|---|---|---|
| M0 | Foundations | Package (`build.zig`, zon, standalone tests); pure Zig (LM, Jacobi, exact predicates ported; `Parallel` interface); the §5 model (edge records with intervals, coedge partners, intrusive loop lists, flags, tags, `Tolerance`); geometry kinds incl. ellipse, extrusion, revolution, with the full parametric contract; NURBS core algorithms; hashed-grid interning; transforms over all kinds (uniform scale and rigid moves exact, non-uniform scale turns analytic faces into NURBS or is refused, mirror flips `same_sense`); checker v1; body JSON; `Diagnostics`, `Options`, `Limits`, cancel (§4.1); `body.hash()`, trace mode, bench skeleton (§12); rewritten README | `transform` | 7k |
| M1 | Exact primitives and sweeps | Sphere, cone, torus exact (D7 split, degenerate edges); extrude and revolve of sketches of lines and arcs; bbox, volume, area, genus; STEP for every kind | `sphere`, `cone`, `extrude`, `revolve`, `volume`, `surface_area`, `genus`, `bounding_box` | 5k |
| M2 | 2D kernel | Overlay engine; sketch booleans, offset, hull, contours, measures; planar tessellation (monotone + Lawson) | `sketch_boolean`, `offset` (sketch), `sketch_hull`, `sketch_measure`, `sketch_contours`, `polygon` | 5k |
| M3 | Meshing and queries | Edges-first tessellation of curved faces with per-face ranges; point-in-body; ray cast; min gap; face queries; plane section (`slice`) via imprint; per-face material attribute | `mesh`, `contains_point`, `ray_cast`, `min_gap`, `faces`, `slice`, `materials` | 5k |
| M4 | Booleans on planar bodies | The full §7.4 pipeline with planes only; BVH; containment table; batch chains; `trim_by_plane`, `decompose`, `empty`; fuzz harness; degeneracy corpus (planar part) | `boolean` (planar), `trim_by_plane`, `decompose`, `empty` | 6k |
| M5 | Booleans on analytic bodies | Exact pair tables; coincidence and tangency detection; marching with Newton for the rest; approximate curves and pcurves with recorded gaps; simplify for curved faces; curved hull as a polyhedron at `Resolution`, documented approximate | `boolean` (all), `curved_hull` | 5k |
| M6 | NURBS surfaces | Loft (skinning), sweep along a path, twisted and tapered extrude; general surface–surface marching; projection (silhouettes) | `loft`, `extrude_twist`, `extrude_scale`, `project` | 5k |
| M7 | Local operations | Exact analytic offsets, shell, convex Minkowski; fillet phase 1 (single edge, constant radius) and chamfer on the four-axis option structure; then phase 2 (tangent chains) and phase 3 (corners) | `offset` (solid), `minkowski`, fillets | 6k |
| M8 | Interop and API | C API with opaque handles and error codes; binary body format; parallel tessellation and intersection (browser workers as a `Parallel`); STEP reader (AP203/214 B-Rep subset, with the input normalizer) last, once M4–M7 are stable | — | 4k |

Order rationale: M0 is the only milestone with no new capability and must come first
because every later one would otherwise be rewritten; M1–M3 give KupCAD exact single
parts with pictures, measures and STEP, which is already a usable B-Rep mode; M4 before M5
because every boolean difficulty exists on planes and is debugged there without surface
intersection noise; M6–M8 are independent of each other.

"Never" within this plan: non-manifold topology, a healer, exact rational arithmetic,
randomized incremental Delaunay as the tessellator, BSP booleans, F-rep evaluation,
assemblies, features.

**Extension points.** The plan leaves room, in these places and no others, for what is
not scheduled: a new curve or surface kind (one array, one `switch` arm per contract
function, §3); a new `Parallel` implementation (browser workers, a thread pool, §4);
the fillet option axes (§7.8); N-ary booleans by General Fuse cells (D17); closed-form
mass properties replacing quadrature (§7.6); a STEP reader behind the same body JSON and
normalizer (§7.9); a C API over the Zig one (M8); per-face attributes beyond a `u32`
through the tag table (§8). Anything else new is a plan change first (§11).

---

## 11. Decisions

| # | Decision | Instead of | Why |
|---|---|---|---|
| D1 | Explicit `Edge` records with `[t0, t1]`; coedges reference them | Curve id on each half-edge, full circles | An edge's geometry stored once; parameter intervals make edge identity unambiguous (H p.203); OCCT, SMLib, Stroud all have it |
| D2 | Intrusive index lists for face→loops, shell→faces, body→shells | `(start, len)` ranges | O(1) insertion anywhere; the range form corrupted `kemr` |
| D3 | A `Body` owns its arenas; operations return new bodies | Many solids in shared arenas | Value semantics make "inputs untouched on failure" and the DAG cache trivial; it is how the driver already uses Locus |
| D4 | Pure Zig; `Parallel` injected | Eigen + oneTBB C++ bridges | Standalone build, Wasm without flags, one toolchain; the numeric routines are small |
| D5 | One `Tolerance` per body (zone / xsect / approx / angle), gaps recorded per entity, never grown | Per-entity tolerances, global constants | SMLib's scheme with its stale-tolerance lesson; KupCAD's parity rule that one `tolerance` means the same on both kernels |
| D6 | Exact predicates for 2D combinatorics, thick tolerances for 3D classification | One epsilon everywhere | Consistent sweeps and flips; tolerances where exactness is impossible (RTCD ch. 11) |
| D7 | Faces are never periodic: split at seams | One face with a seam edge | Removes a class of defects every seam-based kernel still has; SolveSpace's experience |
| D8 | Analytic surfaces plus extrusion and revolution kinds; NURBS only where needed | Everything as NURBS | Exact primitives, exact extrude/revolve, trivial STEP, cheap intersections for most of KupCAD's models |
| D9 | Map overlay in UV as the one face-splitting engine | 3D segment slicing per face | Exact combinatorics; shared between 2D and 3D; the deleted attempt's slicer is what hung |
| D10 | Stroud's stepwise boolean, Hoffmann's once-only incidence, no post-repair | Split then heal | §2 |
| D11 | Approximate curves and pcurves allowed, flagged, within `approx` | Exact or nothing | Plane∩torus and cylinder∩cylinder have no closed form; every kernel approximates here |
| D12 | Degenerate edges for poles and apices | Vertex loops, pole-free spheres | Standard in OCCT/SMLib/STEP; keeps every face a UV box |
| D13 | Edges-first tessellation, monotone partition then Lawson flips | Bowyer–Watson with boundary recovery | Watertight by construction; deterministic; CDT in a dozen lines |
| D14 | Tags and a change log for naming | Stable indices | Indices renumber on compaction; tags copy on split and union on merge |
| D15 | A checker that returns findings, run after every operation in tests | Boolean `isValid`, repair | The test oracle must say what and where |
| D16 | Interferences resolved in dimension order (V–V … E–F) before face–face curves | Face–face first, then repair | Coincidences are found where they are cheap and exact; OCCT's order, 20 years of fixes behind it |
| D17 | Two-body Mäntylä selection first; General Fuse cell algebra later for N-ary batches | General Fuse from the start | The two-body pipeline is debuggable on planes in M4; cells generalise it without changing phases 0–3 |
| D18 | A mirror leaves a surface's frame left-handed; normals carry the frame's sign | Reparameterizing mirrored faces (`u → −u`, loops and pcurves remapped) | Every parameter, pcurve and edge range stays as it was; STEP and OCCT allow indirect placements (2026-11-06) |
| D19 | NURBS knots stored as the full vector; multiplicities derived on export | Distinct knots plus multiplicities | The book's algorithms index the full vector; repeated knots are exact copies made by insertion (2026-11-06) |
| D20 | A non-uniform scale keeps planes, lines and NURBS; the other curved kinds are `NotRepresentable` and the driver refuses them as a feature | Converting them to NURBS | A circle's NURBS form has another parameterization: the stored pcurves would not fit it (2026-11-06) |
| D21 | `Checkpoint` is a copy of the body | A snapshot of the tables' lengths | Operators relink existing entities, which a length snapshot cannot undo (2026-11-06) |
| D22 | The trace is a sink the host supplies (`Trace{context, write}`), fed body JSON per phase by `io/trace.zig`; an operation may import `io` for it | A directory path Locus writes into | Locus touches no file system (§4's targets); the host (`kupcad dev brep-trace`) names and writes the files (2026-11-06) |
| D23 | KupCAD's driver keeps the first finding of a failed operation on the thread, and the script's error carries it (`polygon failed: an edge is shorter than …`) | The kernel interface's null alone | The driver interface answers a failure with null and the findings would be lost; the reason is what a readiness report is for (2026-11-06) |
| D24 | A hull of a sketch with arcs is refused by the driver (`curved_hull`, as a curved solid's hull is) until the hull keeps arcs; Locus's `sketch/hull.zig` hulls the vertices and the arcs' extreme points, documented | Answering the polygon through the extreme points | A disc's hull of area 2r² is a stand-in for πr², the kind of answer the parity rules forbid; the arc hull (tangent lines between arcs) is a later item (2026-11-06) |
| D25 | A sketch offset is the sheet plus or minus the band its boundary sweeps (sweeps and joins as simple regions, one overlay input, positive winding) | The displaced outline filled by its winding (Chen–McMains) | A feature thinner than the offset turns its displaced outline inside out with positive winding: a sliver shrunk past its width kept a region of area 0.94, and each further offset of that garbage grew it fivefold until the overlay's nesting never ended (the fuzzer, 2026-11-08); the band is the definition of the offset itself (points within the distance of the boundary) and needs no rule about self-intersections |
| D26 | In the 2D overlay the circle is the primary object and an arc piece is the interval between two cut points ordered around it by exact predicates (quadrant signs, then `orient2d` about the centre); the welded ends are the vertices; the remaining radical comparisons (discriminant, crossing in segment, which crossing a ray meets first) are exact by squaring and expansions | Arcs as `{c, r, ccw}` beside welded ends with `atan2` span tests (today); ends plus bulge | An arc's ends are off its circle by rounding; angles are transcendental and decided topology in `lineArc`/`arcArc`; bounded-depth radicals over `f64` need no big numbers (research/li-chen-egc.md §2; Leo, 2026-11-09) |

---

## 12. Running it: caches, hashes, tools, performance

Things no book covers because they belong to a library in use.

**Derived data.** A body is immutable once returned, so anything computed from it can be
cached beside it without ever going stale: per-face AABBs and UV boxes, the face BVH, the
tessellation for a given `Resolution`, the edge polylines. `Body.derived` holds them,
built on first use, dropped with the body. The viewer casts a ray at every pointer move
and asks for the mesh at every redraw; both must be answered from the cache, not rebuilt.

**Content hash.** `body.hash()` is a 64-bit hash of the canonical serialization (the body
JSON's byte stream). KupCAD's DAG cache and export fingerprints can use it in place of
hashing a mesh; the determinism test compares it; two bodies built from the same inputs
on different machines must hash alike.

**Scale guard.** `f64` carries about 16 significant digits; a `zone` of 1e-5 mm on a model
whose coordinates reach 1e9 mm is below their representable spacing and every predicate
of tier 2 degrades. The rule is a ratio, `zone ≥ magnitude · 1e-12` with the magnitude the
largest coordinate of the body's vertices (about 64 ulp, with a digit of margin): a part a
kilometre from the origin passes at `zone = 1e-5` and fails at `1e-8`. The checker applies
it at its geometric level, so every built, moved or loaded body is caught with both numbers
in the finding (`too_large_for_tolerance`, 2026-11-09, research/opengeometry.md §1), and
`input.scale` applies it to sizes before anything is built; the fix is the host's (scale
the model or raise the tolerance), as SMLib's decade table implies.

**Trace.** Every operation can be run with `options.trace` set to a sink (`Trace`: a
context and a `write(context, operation, phase, body_json)` function), which receives the
operation's arguments first (`arguments`: the inputs that are not bodies, as JSON of
plain data, for a replay), then the body as JSON after each phase (`io/trace.zig`;
`transform` reports `mapped` and `checked`, a boolean will report `paved`, `imprinted`,
…), so a failing boolean is inspected as a sequence of valid bodies rather than a stack
trace (Stroud: "print or draw any entity", S p.605) and rerun from its inputs. Locus
writes no files (§4's targets); the host does: KupCAD's `kupcad dev brep-trace <script>`
writes `001-transform-arguments.json`, `002-transform-mapped.json`,
`003-transform-checked.json`, … beside the script; the playground can later load a trace
and show each phase.

**Fixtures.** Body JSON fixtures carry a format `version`; they are regenerated only by
`zig build test -Dupdate-snapshots` and the diff is reviewed like code, as KupCAD does
for its example snapshots. A fixture that changes without a geometry change is a
determinism bug.

**Performance.** Measured, never assumed (the project's rule). `test/bench/` times, on
fixed inputs: a 1,000-face planar boolean, a 100-face quadric boolean, tessellation of
10,000 faces, a ray cast on a 10,000-face body (budget: well under a millisecond from the
cache, since the viewer calls it per pointer move), STEP export of 1,000 faces, and a
`compact()` of 1e6 entities. Budgets are set from the first measurements and the suite
fails on a regression of more than 20%. Algorithmic choices in this plan (BVH culling,
grid welding, edges-first meshing) are the ones that remove quadratic behaviour; constant
factors wait for the profiler.

**CI.** Locus's own `zig build test` runs in Debug and ReleaseSafe on Linux, macOS and
Windows, and under wasmtime for `wasm32-wasi`, in KupCAD's workflow; allocation-failure
and determinism tests on every run; the fuzz harness for a fixed budget nightly.

**Readiness.** A `kupcad dev brep-readiness` report runs every example and documentation
snippet with `engine: :brep` and lists, per script, the features still refused; each
milestone's exit criteria name the examples that must newly build. It ends with the
case rig's ladder (§9.3): each tier's counts of pass, fail, crash, hang and refused by
design, with its frontier.

## 13. Risks

- **Tangent and coincident configurations** are where every kernel still breaks (SMLib
  `KNOWN_ISSUES.md`, OCCT's and SolveSpace's issue histories). Mitigation: detect them
  first by surface comparison, imprint rather than intersect, and keep the corpus.
- **Tolerance stacking** across approximated curves and pcurves in chained booleans.
  Mitigation: gaps are measured, not assumed, and the checker fails a result that exceeds
  `zone`; `approx = zone/2` leaves room for one re-approximation.
- **Arcs in the exact tier**: arc–arc intersections are constructed, so 2D combinatorics
  over sketches with many tangent arcs depend on welding. Mitigation: weld immediately,
  and treat tangent arcs as a corpus case.
- **Determinism across platforms** depends on `libm` only in constructions; a welded
  construction that lands on the far side of a tolerance boundary on one platform would
  change topology. Mitigation: the determinism test runs in CI on Linux, macOS and
  Windows; tolerance boundaries are far from constructed values in the fixtures.
- **Scope**: the "later/never" lists are the defence.
