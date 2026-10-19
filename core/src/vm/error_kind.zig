//! The error classes the runtime itself raises. The stdlib registers one class per kind
//! (all subclasses of StandardError), and VM.raiseError raises an instance of the kind's
//! class, so scripts can `rescue ValueError => e` and `e.message` holds only the message.

/// GeometryError messages for a kernel operation that returned no result / an invalid solid.
/// `{s}` is the operation's script name (dag.scriptName or the method name).
pub const KERNEL_FAILED_FMT = "{s} failed: the geometry kernel could not compute a result";
pub const INVALID_RESULT_FMT = "{s} produced invalid geometry: {s}";
/// The engine's script name and what it can't do (kernel.Feature.describe).
pub const UNSUPPORTED_FMT = "the {s} engine can't {s} yet; build this part with engine: :manifold";
/// TypeError for a JsonObject looked up by a key that is neither a String nor a Symbol;
/// `{s}` is the key's type.
pub const JSON_KEY_FMT = "a JsonObject's keys are Strings or Symbols, got {s}";

pub const ErrorKind = enum {
    RuntimeError,
    ArgumentError,
    TypeError,
    ValueError,
    IndexError,
    /// A key a JsonObject's `fetch` or `dig` doesn't find.
    KeyError,
    RangeError,
    ZeroDivisionError,
    MathError,
    NameError,
    NoMethodError,
    NotImplementedError,
    /// The geometry kernel failed an operation or produced an invalid solid.
    GeometryError,
    ImportError,
    OutOfMemoryError,
    AssertionError,
};
