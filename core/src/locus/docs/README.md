# Locus: Native Zig B-Rep CAD Kernel

**Version:** 0.1.0 (Integration with KupCAD)

**Language:** Zig (master/0.17.0-dev)

**Paradigm:** Data-Oriented Design (DoD), Immutable Operations, Tolerant Winged-Edge Topology

**Locus** is a high-performance Boundary Representation (B-Rep) geometry kernel written entirely in Zig. It serves as the analytical backend for **KupCAD**, providing mathematically exact solid modeling, strict topological validation, spatial querying, and ISO-compliant STEP data export.

Unlike traditional object-oriented CAD kernels (which rely on heavily fragmented pointer graphs), Locus is built from the ground up using strict **Data-Oriented Design (DoD)** principles. It completely decouples mathematical geometry from structural topology, utilizing flat memory arenas and strongly-typed indices to guarantee cache locality, eliminate pointer invalidation, and ensure seamless Garbage Collector (GC) tracking.

---

## 1. Architectural Philosophy & Core Invariants

Locus is built to support high-throughput, multithreaded, JIT-compiled parametric CAD scripts. It operates under strict invariants:

1. **Strict Domain Isolation:** Coordinates and parametric equations (`Geometry`) are completely separated from the winged-edge boundary graph (`Topology`). Topological nodes do not contain math; they only contain relational indices.


2. **Zero-Pointer Graph (Typed Indices):** There are no raw memory pointers (`*Face`, `*HalfEdge`) in Locus. All relationships are defined via strongly-typed, compiler-enforced enums (e.g., `FaceIndex`, `CurveIndex`). This allows arrays to be reallocated and shifted safely in memory.


3. **Structural Immutability:** To safely support KupCAD's Directed Acyclic Graph (DAG) caching, all high-level topological modifiers perform deep clones of the source geometry into a destination arena before applying mutations. This prevents accidental cache poisoning.


4. **Thread-Safe Determinism:** Locus relies on stateless pure functions and dynamic environments (`MathEnv`) rather than global variables. Operations yield the exact same bitwise topology regardless of OS or thread scheduling.



---

## 2. Data-Oriented Arenas & Packing

State is managed via two primary contiguous memory containers:

### The Geometry Arena

Maintains pure mathematical definitions. It contains no connectivity data.

* **0D:** `math.Vec3` coordinates.


* **1D (Curves):** Lines, Circle Arcs, NURBS Curves.


* **2D (Surfaces):** Planes, Cylinders, Cones, Spheres, Toruses, NURBS Surfaces.



### The Topology Arena

Maintains the hierarchical **Winged-Edge / Half-Edge** data structure.

* **Vertex:** A topological junction pointing to a `PointIndex` and owning a local `tolerance` sphere.
* **HalfEdge:** A directed edge traversing the perimeter of a Face. Tracks its `twin` (adjacent face), `next`, `prev`, and associated `CurveIndex`.


* **Loop:** A closed boundary of Half-Edges. Faces have one outer loop and $N$ inner loops (holes).


* **Face:** A bounded region resting on a `SurfaceIndex`.


* **Shell:** A cohesive, interconnected collection of faces.


* **Solid:** A physical 3D body consisting of one or more shells.



**DOD Packing:** Geometry references use 32-bit packed structs (`CurveId`, `SurfaceId`). These pack a 24-bit integer index alongside an 8-bit enum tag (e.g., `.plane`, `.nurbs`), maximizing alignment density while maintaining polymorphic routing.

---

## 3. Tolerant Modeling & `MathEnv`

Production CAD files (e.g., imported STEP files) are notoriously imprecise. Locus does not assume mathematically perfect intersections.

1. **Adaptive Tolerancing:** Floating-point precision degrades as geometry moves away from the origin. The `MathEnv` context dynamically inflates intersection tolerances relative to the bounding box of the active operation.


2. **Grazing Angles:** During boolean SSI, if two surfaces intersect at a near-parallel "grazing" angle, the `MathEnv` artificially inflates the collision tolerance using the dot-product to absorb floating-point drift.


3. **Tolerant Vertices:** A `Vertex` in Locus is not an infinitely small point; it is a conceptual sphere. During the `weldSolidVertices` healing phase, vertices with overlapping tolerance spheres are safely collapsed into a single topological entity.


4. **O(1) Precomputations:** `MathEnv` caches the squared values of its tolerances (`vertex_tol_sq`) upon initialization, saving millions of costly square-root calls inside hot loop distance checks.

---

## 4. Periodic Surfaces & Seams

Analytical shapes like Cylinders, Spheres, and Toruses are **periodic** (their parametric $(U, V)$ spaces wrap from $2\pi$ back to $0$).

* A closed cylinder face requires a topological **Seam** (a Half-Edge twin pair mapping to the exact same 3D curve but existing at opposite parametric bounds).


* Developers must ensure that `surfaceProject` and `evaluate` routines correctly handle UV-space wrapping, especially when stepping over the seam during intersection marching.



---

## 5. Persistent Naming (Topological Naming Problem)

Parametric modeling requires that edges and faces retain stable identities when the user changes a parameter (e.g., modifying a cylinder's radius shouldn't break the fillet applied to its top edge).

* Locus solves this by maintaining stable provenance tracking during Booleans. When a face is split by `sliceFace`, the newly generated sub-faces inherit the core identity, attributes, and material tags of the parent `FaceIndex`.


* When rebuilding the DAG, topological queries (e.g., `queryFaces`) dynamically search for faces matching stable spatial criteria (normal vector, relative centroid) rather than relying on brittle raw integer IDs.



---

## 6. The Boolean Pipeline & Healing

Constructive Solid Geometry (CSG) is evaluated using a multi-phase, exact intersection algorithm:

1. **Piercing (0D):** Raycasts edges against target surfaces to identify discrete collision points.


2. **Seam Generation (1D):** Uses explicit math (e.g., intersecting planes/quadrics) or the Levenberg-Marquardt Non-Linear solver to generate boundary curves between the 0D points.


3. **Parallel Classification:** Uses multi-threaded raycasting to classify split faces as `.inside`, `.outside`, `.same`, or `.opposite`.


4. **Healing (Topological Resolution):**
* **Degenerate Collapse:** Micro-edges smaller than `MathEnv.vertex_tolerance` are eliminated.


* **Coplanar Annihilation:** Faces lying on identical mathematical planes are merged, dissolving interior boolean seams back into a unified 2-manifold surface.





---

## 7. Quality Assurance: Fuzzing & Sanity Checking

Production kernels must never panic or crash the host application. Locus utilizes extreme randomized fuzzing to guarantee memory safety and engine stability.

* **Fuzzer Directives:** The suite in `fuzz_test.zig` applies extreme random rotations, massive non-uniform scaling, and zero-length slices. Operations are expected to either succeed or return a clean topological error, but *must never* segfault, infinite loop, or leak memory.


* **BRepSanitizer:** A strict topological auditor runs after boolean operations. It asserts that every `HalfEdge` has a valid twin, that no vertices are unreferenced, and verifies the Euler-Poincaré invariant ($V - E + F = 2S$) for mathematically closed shells.



---

## 8. Developer Guardrails (Rules for LLMs & Engineers)

When proposing code changes to Locus, you **must** obey the following rules:

1. **NO RAW POINTERS:** Never use `*Face` or `*Vertex`. You must use `TopologyArena.faces.items[@intFromEnum(face_id)]` using strictly typed `FaceIndex`.


2. **PREVENT C-STACK OVERFLOWS:** Never use deep recursion for traversing the graph. Winged-edge loops must be traversed iteratively using `while` loops equipped with a `safety_counter` limit (e.g., `10_000`) to prevent kernel hanging on corrupted cyclic graphs.


3. **RESPECT THE MATH_ENV:** Do not hardcode `< 0.0001` or `1e-5` anywhere. You must pass `MathEnv.absolute` or `MathEnv.parametric` for floating point comparisons.


4. **USE EPSILON FOR DIV BY ZERO ONLY:** `math.MATH_EPSILON` (1e-12) is reserved strictly for guarding against division-by-zero or NaN generation (e.g., matrix determinants, vector normalization). It is *not* a geometric tolerance limit.


5. **CLEAN UP YOUR ARENAS:** If an operation allocates intermediate geometry (like a bounding box or temporary edge) during evaluation and aborts via an error (`try` / `catch`), ensure you use `errdefer` to free or rollback the arena additions to prevent memory leaks.
