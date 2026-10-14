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
    ImportError,
    OutOfMemoryError,
    AssertionError,
};
