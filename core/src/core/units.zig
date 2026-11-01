//! Millimetres in the units a file may be in, for the importers (3MF, DXF and SVG each kept
//! numbers of their own) and whatever else converts.

/// An inch, exactly.
pub const MM_PER_INCH = 25.4;
pub const MM_PER_FOOT = 12 * MM_PER_INCH;
pub const MM_PER_YARD = 3 * MM_PER_FOOT;
pub const MM_PER_MILE = 1760 * MM_PER_YARD;
pub const MM_PER_METER = 1000.0;
/// CSS's pixel, SVG's user unit when the file says nothing else, is a 96th of an inch.
pub const CSS_PX_PER_INCH = 96.0;
pub const MM_PER_PX = MM_PER_INCH / CSS_PX_PER_INCH;
