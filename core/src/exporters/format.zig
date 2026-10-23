//! The formats a model exports to (`ExportFormat`: what each holds and needs, its names and
//! extensions, read by `kupcad build`, the browser build and the export) and how it is
//! written beyond its format (`ExportOptions`: what build's flags ask for).

const std = @import("std");
const geom = @import("../core/geometry_handle.zig");
const gltf_exporter = @import("3d/gltf.zig");
const svg_exporter = @import("2d/svg.zig");

/// The formats a model exports to. The tag names are what `kupcad build --format` and the
/// browser build call them; the format travelled as a string, compared at every use. What
/// each can hold and needs is read from here (its dimension, extensions, Draco, engine),
/// where it was spread over the CLI's tables and the exporters' checks.
pub const ExportFormat = enum {
    stl,
    glb,
    gltf,
    step,
    /// 3D Manufacturing Format: each part once, placed once per copy (exporters/3d/threemf.zig).
    @"3mf",
    /// Wavefront OBJ: an object per Solid, in millimetres and Z up (exporters/3d/obj.zig).
    obj,
    /// A drawing of the model's Sketches, and its Solids projected onto XY (exporters/2d/svg.zig).
    svg,
    /// The same drawing as DXF, a closed polyline per contour on a layer per name (exporters/2d/dxf.zig).
    dxf,

    /// What a format holds: a 3D format the model's Solids, a 2D one its Sketches.
    pub const Dimension = enum { @"2d", @"3d" };

    /// "stl, glb, gltf, step, 3mf", for messages.
    pub const NAMES = blk: {
        var list: []const u8 = "";
        for (@typeInfo(ExportFormat).@"enum".field_names, 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
        break :blk list;
    };

    /// ".stl, .glb, .gltf, .step, .stp, .3mf", for messages.
    pub const EXTENSIONS = blk: {
        var list: []const u8 = "";
        for (std.enums.values(ExportFormat)) |format| {
            for (format.extensions()) |ext| list = list ++ (if (list.len == 0) "" else ", ") ++ ext;
        }
        break :blk list;
    };

    /// The format named `name`, or null for a name that is none.
    pub fn parse(name: []const u8) ?ExportFormat {
        return std.meta.stringToEnum(ExportFormat, name);
    }

    /// The format an output file's extension (`.stl`, in any case) implies, or null.
    pub fn forExtension(ext: []const u8) ?ExportFormat {
        for (std.enums.values(ExportFormat)) |format| {
            for (format.extensions()) |candidate| {
                if (std.ascii.eqlIgnoreCase(ext, candidate)) return format;
            }
        }
        return null;
    }

    pub fn dimension(self: ExportFormat) Dimension {
        return switch (self) {
            .stl, .glb, .gltf, .step, .@"3mf", .obj => .@"3d",
            .svg, .dxf => .@"2d",
        };
    }

    /// The file extensions written in it, the usual one first (`extension`).
    pub fn extensions(self: ExportFormat) []const []const u8 {
        return switch (self) {
            .stl => &.{".stl"},
            .glb => &.{".glb"},
            .gltf => &.{".gltf"},
            .step => &.{ ".step", ".stp" },
            .@"3mf" => &.{".3mf"},
            .obj => &.{".obj"},
            .svg => &.{".svg"},
            .dxf => &.{".dxf"},
        };
    }

    /// The extension a file written in it gets, with its dot.
    pub fn extension(self: ExportFormat) []const u8 {
        return self.extensions()[0];
    }

    /// Whether a material library (`.mtl`) can go beside it: OBJ's.
    pub fn supportsMaterialLibrary(self: ExportFormat) bool {
        return switch (self) {
            .obj => true,
            .stl, .glb, .gltf, .step, .@"3mf", .svg, .dxf => false,
        };
    }

    /// Whether its meshes can be Draco-compressed (a glTF extension).
    pub fn supportsDraco(self: ExportFormat) bool {
        return switch (self) {
            .glb, .gltf => true,
            .stl, .step, .@"3mf", .obj, .svg, .dxf => false,
        };
    }

    /// Whether it draws outlines with a stroke of a width (`ExportOptions.stroke_width`).
    pub fn supportsStrokeWidth(self: ExportFormat) bool {
        return switch (self) {
            .svg => true,
            .stl, .glb, .gltf, .step, .@"3mf", .obj, .dxf => false,
        };
    }

    /// Whether it holds the ghosts the script showed beside the model: the viewer's
    /// formats do, a file for a slicer or a CAD package doesn't.
    pub fn showsGhosts(self: ExportFormat) bool {
        return switch (self) {
            .glb, .gltf => true,
            .stl, .step, .@"3mf", .obj, .svg, .dxf => false,
        };
    }

    /// The engine the script must run on for it, if it needs one: STEP needs exact
    /// B-Rep geometry, not meshes.
    pub fn requiredEngine(self: ExportFormat) ?geom.EngineType {
        return switch (self) {
            .step => .brep_native,
            .stl, .glb, .gltf, .@"3mf", .obj, .svg, .dxf => null,
        };
    }
};

/// How a model is exported, beyond its format: what `kupcad build`'s flags ask for.
pub const ExportOptions = struct {
    /// Compress glb and gltf meshes with Draco.
    draco: bool = false,
    /// The bits Draco quantizes positions to (1 to MAX_DRACO_POSITION_BITS): finer files
    /// are larger.
    draco_bits: u8 = gltf_exporter.DEFAULT_DRACO_POSITION_BITS,
    /// An SVG's outline width, in mm.
    stroke_width: f64 = svg_exporter.DEFAULT_STROKE_WIDTH,
    /// The material library an OBJ names (`mtllib`), written by `exportMaterialLibrary`;
    /// null for an OBJ without materials.
    mtl_name: ?[]const u8 = null,
};
