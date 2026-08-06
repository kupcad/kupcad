pub const TokenTypeCategory = enum {
    keyword,
    primitive_3d,
    primitive_2d,
    transform,
    csg_operator,
    workplane_method,
    inspection_method,
};

pub const TokenMeta = struct {
    name: []const u8,
    category: TokenTypeCategory,
};

pub const LANGUAGE_TOKENS = [_]TokenMeta{
    // Keywords
    .{ .name = "def", .category = .keyword },
    .{ .name = "class", .category = .keyword },
    .{ .name = "import", .category = .keyword },
    .{ .name = "export", .category = .keyword },
    .{ .name = "from", .category = .keyword },
    .{ .name = "with", .category = .keyword },
    .{ .name = "module", .category = .keyword },
    .{ .name = "end", .category = .keyword },
    .{ .name = "do", .category = .keyword },
    .{ .name = "if", .category = .keyword },
    .{ .name = "else", .category = .keyword },
    .{ .name = "elsif", .category = .keyword },
    .{ .name = "unless", .category = .keyword },
    .{ .name = "while", .category = .keyword },
    .{ .name = "until", .category = .keyword },
    .{ .name = "case", .category = .keyword },
    .{ .name = "when", .category = .keyword },
    .{ .name = "return", .category = .keyword },
    .{ .name = "yield", .category = .keyword },
    .{ .name = "break", .category = .keyword },
    .{ .name = "next", .category = .keyword },
    .{ .name = "begin", .category = .keyword },
    .{ .name = "rescue", .category = .keyword },
    .{ .name = "ensure", .category = .keyword },
    .{ .name = "self", .category = .keyword },
    .{ .name = "super", .category = .keyword },
    .{ .name = "and", .category = .keyword },
    .{ .name = "or", .category = .keyword },
    .{ .name = "not", .category = .keyword },
    .{ .name = "true", .category = .keyword },
    .{ .name = "false", .category = .keyword },
    .{ .name = "nil", .category = .keyword },

    // 3D Primitives
    .{ .name = "box", .category = .primitive_3d },
    .{ .name = "cylinder", .category = .primitive_3d },
    .{ .name = "sphere", .category = .primitive_3d },
    .{ .name = "cone", .category = .primitive_3d },
    .{ .name = "torus", .category = .primitive_3d },
    .{ .name = "polyhedron", .category = .primitive_3d },
    .{ .name = "wedge", .category = .primitive_3d },

    // 2D Profiles
    .{ .name = "rect", .category = .primitive_2d },
    .{ .name = "circle", .category = .primitive_2d },
    .{ .name = "polygon", .category = .primitive_2d },
    .{ .name = "regular_polygon", .category = .primitive_2d },
    .{ .name = "annulus", .category = .primitive_2d },

    // Sweeps & Extrusions
    .{ .name = "extrude", .category = .transform },
    .{ .name = "revolve", .category = .transform },
    .{ .name = "hull", .category = .transform },

    // Transformations & Modifiers
    .{ .name = "translate", .category = .transform },
    .{ .name = "rotate", .category = .transform },
    .{ .name = "scale", .category = .transform },
    .{ .name = "mirror", .category = .transform },
    .{ .name = "center", .category = .transform },
    .{ .name = "offset", .category = .transform },
    .{ .name = "smooth", .category = .transform },
    .{ .name = "refine", .category = .transform },

    // Inspection & Exports
    .{ .name = "bbox", .category = .inspection_method },
    .{ .name = "volume", .category = .inspection_method },
    .{ .name = "to_mesh", .category = .inspection_method },

    // CSG Booleans
    .{ .name = "union", .category = .csg_operator },
    .{ .name = "difference", .category = .csg_operator },
    .{ .name = "intersect", .category = .csg_operator },

    // Workplanes
    .{ .name = "on_face", .category = .workplane_method },
};
