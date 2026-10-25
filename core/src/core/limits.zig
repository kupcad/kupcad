//! The fixed limits of the language and its runtime: bytecode operand widths, AST depth,
//! instruction and memory budgets for interactive runs, and caps on user-supplied geometry
//! counts, source size, data files and B-Rep solver iterations.

const std = @import("std");
const builtin = @import("builtin");

// Bytecode & Operand Limits
pub const MAX_CONSTANTS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_SHORT_CONSTANTS: usize = std.math.maxInt(u8); // 255
pub const MAX_LOCALS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_UPVALUES: usize = std.math.maxInt(u8); // 255
pub const MAX_ARGS: usize = std.math.maxInt(u8); // 255
pub const MAX_HASH_ENTRIES: usize = MAX_CONSTANTS / 2; // 32_767
pub const MAX_AST_DEPTH: usize = 1500;

// Runtime Execution Limits
/// Most instructions one run may take where a person waits on it: the browser's worker and
/// the editor's language server, which answers nothing else while a script runs. A script
/// that loops forever stops with an error there instead of hanging them.
pub const INTERACTIVE_INSTRUCTION_LIMIT: usize = 100_000_000;
/// Most script heap (strings, arrays, maps, instances: what the GC tracks, and the geometry
/// graph's tables the run grows; not the kernel's meshes) one run may hold where a server runs scripts for others (the language server,
/// `kupcad watch`): a loop that fills an array forever stops with an error instead of
/// taking the machine down. A project sets its own with `vm_memory_limit` in .kupcad.json.
pub const INTERACTIVE_MEMORY_LIMIT: usize = 1024 * 1024 * 1024;
// Compile-Time Platform Detection:
// WASM -> the interactive cap, to protect Web Worker UI threads
// Native Desktop -> 0 (Unlimited gas for heavy local batch modeling)
pub const DEFAULT_INSTRUCTION_LIMIT: usize = if (builtin.target.cpu.arch == .wasm32)
    INTERACTIVE_INSTRUCTION_LIMIT
else
    0;

// Geometry input limits
// Upper bound for any user-supplied tessellation count (segments, sides, slices,
// CAD.config resolution segments). Chosen so that MAX_SEGMENTS^2 (~4.2M) stays under the default
// 5M `max_vertices` budget in engine_config.zig: two-parameter surfaces such as a
// sphere or torus scale quadratically, and that budget is only enforced *after*
// the kernel has already allocated the mesh.
pub const MAX_SEGMENTS: i32 = 2048;
// Upper bound for repeat_linear / repeat_polar copy counts. Each copy adds a
// translate node plus a union node to the DAG, so this caps DAG growth per call.
pub const MAX_PATTERN_COUNT: usize = 10_000;
// Most points a sweep follows: each adds an extrusion and a corner's revolve to the DAG.
pub const MAX_SWEEP_POINTS: usize = 10_000;
// Largest array a range may materialize (Range#to_a, and the array Range#map returns).
// Block-driven iteration (each, times, upto, downto) is NOT capped: every block call runs
// through the dispatch loop, which checks cancellation and the instruction budget, just
// like a `while` loop. Building an array is bounded by memory instead: 10M values is
// ~130 MB, and the native build has no memory limit by default.
pub const MAX_RANGE_MATERIALIZE: usize = 10_000_000;
// Most characters String#rjust and #ljust add, and the widest a `%` format's directive is.
// A label or a table column is far shorter, and the padding is written in the native,
// where the instruction budget can't stop it.
pub const MAX_STRING_PAD: usize = 1_000_000;
// Most corners a polyhedron's face has. A face is triangulated by ear clipping in the native
// (core/triangulate.zig), O(n²) in its corners, where the instruction budget can't stop it;
// a cap of a cylinder drawn at the finest resolution has MAX_SEGMENTS.
pub const MAX_FACE_CORNERS: usize = 4096;
// Upper bounds for the B-Rep solver iteration budgets set via CAD.config(brep: ...).
// Both are per-call loops, so an unbounded user value turns one projection or
// intersection into an effective hang. The caps sit 20x/200x above the defaults
// in engine_config.zig (50 and 500); Newton converges quadratically, so a root
// not found within 1000 trials is diverging, not slow.
pub const MAX_NEWTON_TRIALS: u32 = 1_000;
pub const MAX_MARCHING_STEPS: u32 = 100_000;

// Frontend & compiler limits
// Largest source accepted by Document.parse. Matches the CLI's file cap so the
// LSP and WASM entry points (which bypass the CLI) get the same protection; it
// also keeps the token count far below MAX_TOKENS (at most one token per byte).
pub const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024; // 10 MiB
// Largest JSON file `import_json` reads: its values take several times its size.
pub const MAX_JSON_BYTES: usize = 64 * 1024 * 1024; // 64 MiB
// Largest drawing `import_dxf` and `import_svg` read: its outlines take several times its size.
// An SVG's <use>s read no more of it again than this either.
pub const MAX_DRAWING_BYTES: usize = 64 * 1024 * 1024; // 64 MiB
// Most elements an SVG drawing's clones (<use>s) draw: nested, they multiply, so a small
// file could ask for more than memory holds.
pub const MAX_DRAWING_PIECES: usize = 1_000_000;
// Most points a DXF drawing's entities place (vertices, centres, ends), a block's as often as
// INSERTs place it: nested, they multiply. More than a drawing of MAX_DRAWING_BYTES gives
// itself (a point takes 10 bytes at least), so only blocks multiplying past that are refused.
pub const MAX_DRAWING_POINTS: usize = 8_000_000;
// Most a 3MF package's files unpack to, together, as `import_3mf` reads them: a zip's file
// says what it unpacks to, so a small archive could ask for more than memory holds (one that
// claims more than deflate makes of its packed bytes is corrupt, before it is allocated).
pub const MAX_PACKAGE_PART_BYTES: usize = 512 * 1024 * 1024; // 512 MiB
// Most triangles a 3MF's build places: components within components multiply, so a small
// file could ask for more than memory holds; and most vertices, as many as the triangles
// could name (an object placed is welded afresh each time, vertex by vertex).
pub const MAX_PLACED_TRIANGLES: usize = 20_000_000;
pub const MAX_PLACED_VERTICES: usize = 3 * MAX_PLACED_TRIANGLES;
// Most meshes a 3MF's build places: each is welded on its own and made a solid, unioned with
// the rest, so a small file placing a small object millions of times would ask for more than
// memory holds, though its triangles stay under their cap.
pub const MAX_PLACED_MESHES: usize = 100_000;
// Most Solids an assembly places, an assembly in it counted each time it is placed: one
// placed twice in each of 25 levels places 2^25, which an export, a BOM or a translate
// walks one by one; as many as a 3MF's build may place.
pub const MAX_ASSEMBLY_SOLIDS: usize = MAX_PLACED_MESHES;
// Largest mesh file `import_stl`, `import_obj` and `import_3mf` read: five million
// triangles as binary STL (50 bytes each), which the kernel takes minutes over already.
pub const MAX_MESH_BYTES: usize = 256 * 1024 * 1024; // 256 MiB
// Largest file the native file system reads for a script at all: the largest any import
// takes. A read allocates the file's size first, so no file past it is read whole.
pub const MAX_READ_BYTES: usize = MAX_MESH_BYTES;
// Most distinct files one run is remembered reading (VM.files_read, which a watching host
// watches): a script trying paths in a loop would have the editor watch each one.
pub const MAX_FILES_READ: usize = 256;
// Largest font file `import_font` reads: the biggest CJK fonts are about 20 MiB, and the file
// stays in memory while the run lasts.
pub const MAX_FONT_BYTES: usize = 32 * 1024 * 1024; // 32 MiB
// Deepest nesting of objects and arrays `import_json` reads, and JsonObject#to_h copies:
// both recurse, one native call level per level.
pub const MAX_JSON_DEPTH: usize = 256;
// The parser stores token indices as u24. Keep one index of headroom so the
// one-token lookahead (`tok_idx + 1`) can never overflow.
pub const MAX_TOKENS: usize = std.math.maxInt(u24) - 1;
// Inline-cache indices are encoded as a 16-bit operand after property/invoke ops.
pub const MAX_INLINE_CACHES: usize = std.math.maxInt(u16); // highest valid index
// op_switch_wide encodes its case count as a 16-bit operand. Larger literal
// `case` statements fall back to linear comparisons instead of a jump table.
pub const MAX_JUMP_TABLE_CASES: usize = std.math.maxInt(u16);
