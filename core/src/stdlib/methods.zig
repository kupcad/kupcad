const booleans = @import("methods/booleans.zig");
const sweeps = @import("methods/sweeps.zig");
const advanced = @import("methods/advanced.zig");
const transforms = @import("methods/transforms.zig");
const inspect = @import("methods/inspect.zig");
const materials = @import("methods/materials.zig");
// booleans
pub const meshUnion = booleans.meshUnion;
pub const meshDifference = booleans.meshDifference;
pub const meshIntersection = booleans.meshIntersection;
// transforms
pub const meshTranslate = transforms.meshTranslate;
pub const meshRotate = transforms.meshRotate;
pub const meshScale = transforms.meshScale;
pub const meshMirror = transforms.meshMirror;
pub const meshTransform = transforms.meshTransform;
pub const meshResize = transforms.meshResize;
// sweeps
pub const meshExtrude = sweeps.meshExtrude;
pub const meshRevolve = sweeps.meshRevolve;
// advanced
pub const meshHull = advanced.meshHull;
pub const meshMinkowski = advanced.meshMinkowski;
pub const meshTrimByPlane = advanced.meshTrimByPlane;
pub const meshOffset = advanced.meshOffset;
pub const meshSlice = advanced.meshSlice;
pub const meshProject = advanced.meshProject;
pub const meshOnFace = advanced.meshOnFace;
// inspect
pub const meshBBox = inspect.meshBBox;
pub const meshVolume = inspect.meshVolume;
pub const meshSurfaceArea = inspect.meshSurfaceArea;
pub const meshMinGap = inspect.meshMinGap;
pub const meshContains = inspect.meshContains;
pub const meshRayCast = inspect.meshRayCast;
// materials
pub const meshMaterial = materials.meshMaterial;
