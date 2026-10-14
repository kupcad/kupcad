//! The error classes the runtime itself raises. The stdlib registers one class per kind
//! (all subclasses of StandardError), and VM.raiseError raises an instance of the kind's
//! class, so scripts can `rescue ValueError => e` and `e.message` holds only the message.

pub const ErrorKind = enum {
    RuntimeError,
    ArgumentError,
    TypeError,
    ValueError,
    IndexError,
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

/// GeometryError messages for a kernel operation that returned no result / an invalid solid.
/// `{s}` is the operation's script name (dag.scriptName or the method name).
pub const KERNEL_FAILED_FMT = "{s} failed: the geometry kernel could not compute a result";
pub const INVALID_RESULT_FMT = "{s} produced invalid geometry: {s}";
