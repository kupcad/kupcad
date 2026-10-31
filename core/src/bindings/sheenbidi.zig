//! Bindings to SheenBidi (vendor/sheenbidi), the Unicode Bidirectional Algorithm: a line's runs
//! of one direction, in the order they are drawn, and its runs of one script. `text`
//! (core/text.zig) splits a line with it before HarfBuzz shapes each run.

pub const Algorithm = opaque {};
pub const Paragraph = opaque {};
pub const Line = opaque {};
pub const ScriptLocator = opaque {};

/// A string's code units: KupCAD's are UTF-8 (`encoding_utf8`).
pub const CodepointSequence = extern struct {
    string_encoding: u32,
    string_buffer: [*]const u8,
    string_length: usize,
};
pub const encoding_utf8: u32 = 0;

/// The paragraph's direction is its first strong character's, left to right without one.
pub const level_default_ltr: u8 = 0xFE;

/// A run of one embedding level, in code units: an odd level runs right to left.
pub const Run = extern struct {
    offset: usize,
    length: usize,
    level: u8,
};

/// A run of one script, in code units.
pub const ScriptAgent = extern struct {
    offset: usize,
    length: usize,
    script: u8,
};

pub extern fn SBAlgorithmCreate(sequence: *const CodepointSequence) ?*const Algorithm;
pub extern fn SBAlgorithmRelease(algorithm: *const Algorithm) void;
pub extern fn SBAlgorithmCreateParagraph(algorithm: *const Algorithm, offset: usize, suggested_length: usize, base_level: u8) ?*const Paragraph;
pub extern fn SBParagraphGetLength(paragraph: *const Paragraph) usize;
pub extern fn SBParagraphCreateLine(paragraph: *const Paragraph, offset: usize, length: usize) ?*const Line;
pub extern fn SBParagraphRelease(paragraph: *const Paragraph) void;
pub extern fn SBLineGetRunCount(line: *const Line) usize;
pub extern fn SBLineGetRunsPtr(line: *const Line) [*]const Run;
pub extern fn SBLineRelease(line: *const Line) void;
pub extern fn SBScriptLocatorCreate() ?*ScriptLocator;
pub extern fn SBScriptLocatorLoadCodepoints(locator: *ScriptLocator, sequence: *const CodepointSequence) void;
pub extern fn SBScriptLocatorMoveNext(locator: *ScriptLocator) u8;
pub extern fn SBScriptLocatorGetAgent(locator: *ScriptLocator) *const ScriptAgent;
pub extern fn SBScriptLocatorRelease(locator: *ScriptLocator) void;
