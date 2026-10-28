//! The Signature of every method of a solid or a sketch (stdlib/manifest.zig lists them).
//! A method that parses keywords parses these, so what it accepts and what the tools
//! say it accepts can't drift apart. A list of shapes (`union`, `hull`) has no names.

const Signature = @import("signature.zig").Signature;
const arguments = @import("arguments.zig");

/// Methods that take nothing but the receiver.
pub const NONE = Signature{};

// --- Booleans: any number of shapes or arrays of them ---
pub const SHAPES = Signature{ .rest = "shapes" };

// --- Transforms ---
pub const TRANSLATE = Signature{ .positional = &arguments.VEC3_NAMES, .keywords = &arguments.VEC3_NAMES };
pub const ROTATE = Signature{ .positional = &arguments.VEC3_NAMES, .keywords = &.{ "x", "y", "z", "angle", "axis", "about" } };
pub const SCALE = TRANSLATE;
pub const MIRROR = TRANSLATE;
pub const RESIZE = Signature{ .positional = &.{"size"}, .keywords = &.{"auto"} };
pub const CENTER = Signature{ .positional = &.{"axes"} };
pub const ALIGN = Signature{ .positional = &.{ "target", "axes", "my_align", "target_align", "offset" } };
pub const TRANSFORM = Signature{ .positional = &.{"matrix"} };
pub const REPEAT_LINEAR = Signature{ .positional = &.{ "count", "x", "y", "z" }, .keywords = &arguments.VEC3_NAMES };
pub const REPEAT_POLAR = Signature{ .positional = &.{ "count", "angle" }, .keywords = &.{"angle"} };

// --- Sweeps (of a sketch) ---
pub const EXTRUDE = Signature{ .positional = &.{"h"}, .keywords = &.{ "h", "slices", "twist", "scale_x", "scale_y", "scale", "center" } };
pub const REVOLVE = Signature{ .positional = &.{"deg"}, .keywords = &.{ "deg", "angle", "segments" } };
pub const HELIX = Signature{ .positional = &.{ "h", "twist", "slices" }, .keywords = &.{ "h", "twist", "pitch", "turns", "slices" } };
pub const LOFT = Signature{ .positional = &.{ "target", "height" } };
pub const SWEEP = Signature{ .positional = &.{"path"}, .keywords = &.{ "path", "segments" } };

// --- Advanced ---
pub const MINKOWSKI = Signature{ .positional = &.{"other"} };
pub const INTERSECTS = Signature{ .positional = &.{"other"} };
pub const TRIM_BY_PLANE = Signature{ .positional = &.{ "nx", "ny", "nz", "offset" }, .keywords = &.{ "nx", "ny", "nz", "offset", "normal" } };
pub const SPLIT_BY_PLANE = TRIM_BY_PLANE;
pub const OFFSET = Signature{ .positional = &.{"delta"}, .keywords = &.{ "delta", "join", "miter_limit", "segments" } };
pub const SHELL = Signature{ .positional = &.{"thickness"}, .keywords = &.{ "thickness", "segments" }, .sizes = &.{"thickness"} };
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
/// `mtl:` by keyword alone: `export_obj(path, true)` didn't say what it turned on
pub const EXPORT_OBJ = Signature{ .positional = &.{"path"}, .keywords = &.{"mtl"} };
