//! The Signature of every method of a solid or a sketch (stdlib/manifest.zig lists them).
//! A method that parses keywords parses these, so what it accepts and what the tools
//! say it accepts can't drift apart. A list of shapes (`union`, `hull`) has no names.

const Signature = @import("signature.zig").Signature;
const util = @import("methods/util.zig");

/// Methods that take nothing but the receiver.
pub const NONE = Signature{};

// --- Booleans: any number of shapes or arrays of them ---
pub const SHAPES = Signature{ .rest = "shapes" };

// --- Transforms ---
pub const TRANSLATE = Signature{ .positional = &util.VEC3_NAMES, .keywords = &util.VEC3_NAMES };
pub const ROTATE = TRANSLATE;
pub const SCALE = TRANSLATE;
pub const MIRROR = TRANSLATE;
pub const RESIZE = Signature{ .positional = &.{"size"}, .keywords = &.{"auto"} };
pub const CENTER = Signature{ .positional = &.{"axes"} };
pub const ALIGN = Signature{ .positional = &.{ "target", "axes", "my_align", "target_align", "offset" } };
pub const TRANSFORM = Signature{ .positional = &.{"matrix"} };
pub const REPEAT_LINEAR = Signature{ .positional = &.{ "count", "x", "y", "z" }, .keywords = &util.VEC3_NAMES };
pub const REPEAT_POLAR = Signature{ .positional = &.{ "count", "angle" }, .keywords = &.{"angle"} };

// --- Sweeps (of a sketch) ---
pub const EXTRUDE = Signature{ .positional = &.{"h"}, .keywords = &.{ "h", "slices", "twist", "scale_x", "scale_y", "scale", "center" } };
pub const REVOLVE = Signature{ .positional = &.{"deg"}, .keywords = &.{ "deg", "segments" } };
pub const HELIX = Signature{ .positional = &.{ "h", "twist", "slices" }, .keywords = &.{ "h", "twist", "slices" } };
pub const LOFT = Signature{ .positional = &.{ "target", "height" } };

// --- Advanced ---
pub const MINKOWSKI = Signature{ .positional = &.{"other"} };
pub const TRIM_BY_PLANE = Signature{ .positional = &.{ "nx", "ny", "nz", "offset" } };
pub const SPLIT_BY_PLANE = Signature{ .positional = &.{ "nx", "ny", "nz", "offset" }, .keywords = &.{ "nx", "ny", "nz", "offset" } };
pub const OFFSET = Signature{ .positional = &.{"delta"}, .keywords = &.{ "delta", "join", "segments" }, .solid_sizes = &.{"delta"} };
pub const SLICE = Signature{ .positional = &.{"height"} };
pub const PROJECT = Signature{ .keywords = &.{"cut"} };
pub const ON_FACE = Signature{ .positional = &.{"direction"} };
pub const SIMPLIFY = Signature{ .positional = &.{"tolerance"} };

// --- Inspection ---
pub const MIN_GAP = Signature{ .positional = &.{ "other", "search_length" }, .sizes = &.{"search_length"} };
pub const CONTAINS = Signature{ .positional = &.{"point"} };
pub const RAY_CAST = Signature{ .positional = &.{ "origin", "end" } };

// --- Materials and files ---
pub const MATERIAL = Signature{ .keywords = &.{ "color", "alpha", "roughness", "metallic", "transmission", "density" } };
pub const NAMED = Signature{ .positional = &.{"name"} };
pub const EXPORT = Signature{ .positional = &.{"path"} };
pub const EXPORT_GLTF = Signature{ .positional = &.{ "path", "draco" } };
pub const EXPORT_OBJ = Signature{ .positional = &.{ "path", "mtl" } };
