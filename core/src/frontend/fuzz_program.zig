//! Programs for the fuzz tests to start from instead of bytes: the fuzzer's input picks each
//! choice (a statement, an expression, a method), so what it mutates is a program, and
//! nearly every input gets past the parser to the compiler, the formatter and the VM.
//!
//! A program is typed as it is written: a variable remembers what it holds, and a method
//! call picks from the real methods of that type (the stdlib's tables: the manifest's
//! globals and shape methods, with their keywords, and the classes' methods), so a run goes
//! on rather than stopping at the first NoMethodError. Methods and classes are called only
//! once defined, with as many arguments as they take; `return`, `break`, `next` and `yield`
//! appear only where they are allowed; loops count to a bound. Each choice's first option
//! is the simplest, and every list and depth is capped, so an exhausted input ends the
//! program.

const std = @import("std");
const Smith = std.testing.Smith;
const manifest = @import("../stdlib/manifest.zig");
const common = @import("../stdlib/classes/common.zig");
const array_class = @import("../stdlib/classes/array.zig");
const string_class = @import("../stdlib/classes/string.zig");
const number_class = @import("../stdlib/classes/number.zig");
const map_class = @import("../stdlib/classes/map.zig");
const range_class = @import("../stdlib/classes/range.zig");
const math_class = @import("../stdlib/classes/math.zig");

pub const Error = error{OutOfMemory};

/// Statements in a whole program.
const MAX_STATEMENTS = 40;
/// Statements in one body (of an `if`, a loop, a method, a block).
const MAX_BODY = 5;
/// Bodies inside bodies.
const MAX_NESTING = 3;
/// Expressions inside expressions.
const MAX_DEPTH = 4;
/// Variables in scope at once, methods and classes in a program.
const MAX_VARS = 24;
const MAX_METHODS = 6;
const MAX_CLASSES = 3;
/// The most a generated loop counts to.
const MAX_LOOP = 4;

/// What an expression gives, as far as the generator keeps track.
const Kind = enum { number, string, boolean, symbol, array, map, range, solid, sketch };

const Var = struct { name: []const u8, kind: Kind };
const Method = struct { name: []const u8, arity: u8 };
const Class = struct { name: []const u8, arity: u8 };

const VAR_NAMES = names("v", MAX_VARS);
const PARAM_NAMES = names("p", 3);
const BLOCK_NAMES = names("x", MAX_NESTING + 1);
const METHOD_NAMES = names("m", MAX_METHODS);
const CLASS_NAMES = names("C", MAX_CLASSES);

fn names(comptime prefix: []const u8, comptime n: usize) [n][]const u8 {
    var out: [n][]const u8 = undefined;
    for (&out, 0..) |*name, i| name.* = std.fmt.comptimePrint("{s}{d}", .{ prefix, i });
    return out;
}

/// Where a program's choices come from.
pub const Choices = union(enum) {
    /// The fuzzer's, which it mutates.
    smith: *Smith,
    /// A seeded generator's, for a plain test run: a Smith reading fixed bytes picks the
    /// first option almost every time (a number out of range falls back to it).
    random: std.Random,
};

/// The odds, one in this many, that a random program ends a list of statements.
const RANDOM_STOP_ODDS = 6;

/// The program for `choices`; the caller owns it.
pub fn generate(gpa: std.mem.Allocator, choices: Choices) Error![]u8 {
    var g: Generator = .{ .gpa = gpa, .choices = choices };
    errdefer g.out.deinit(gpa);
    while (g.statements < MAX_STATEMENTS and !g.stop()) try g.statement();
    return g.out.toOwnedSlice(gpa);
}

const Generator = struct {
    gpa: std.mem.Allocator,
    choices: Choices,
    out: std.ArrayListUnmanaged(u8) = .empty,
    statements: usize = 0,
    nesting: usize = 0,
    vars: [MAX_VARS]Var = undefined,
    vars_len: usize = 0,
    /// The first variable the current method sees (a method doesn't see the script's).
    scope_start: usize = 0,
    methods: [MAX_METHODS]Method = undefined,
    methods_len: usize = 0,
    classes: [MAX_CLASSES]Class = undefined,
    classes_len: usize = 0,
    in_method: bool = false,
    in_loop: bool = false,

    fn emit(g: *Generator, text: []const u8) Error!void {
        try g.out.appendSlice(g.gpa, text);
    }

    fn emitf(g: *Generator, comptime fmt: []const u8, args: anytype) Error!void {
        try g.out.print(g.gpa, fmt, args);
    }

    // Inline, so each choice is a call site of its own: the fuzzer tells them apart by the
    // address Smith is called from.
    inline fn pick(g: *Generator, n: usize) usize {
        return switch (g.choices) {
            .smith => |smith| smith.index(n),
            .random => |random| random.uintLessThan(usize, n),
        };
    }

    /// Whether a list of statements ends here.
    inline fn stop(g: *Generator) bool {
        return switch (g.choices) {
            .smith => |smith| smith.eos(),
            .random => |random| random.uintLessThan(u8, RANDOM_STOP_ODDS) == 0,
        };
    }

    fn newline(g: *Generator) Error!void {
        try g.emit("\n");
        for (0..g.nesting) |_| try g.emit("  ");
    }

    // --- Statements ---

    fn statement(g: *Generator) Error!void {
        g.statements += 1;
        try g.newline();
        const top = g.nesting == 0;
        switch (g.pick(16)) {
            0 => try g.assignment(),
            1 => try g.output(),
            2 => try g.compoundAssignment(),
            3 => try g.ifStatement(),
            4 => try g.whileLoop(),
            5 => try g.forLoop(),
            6 => try g.caseStatement(),
            7 => if (top) try g.methodDefinition() else try g.assignment(),
            8 => if (top) try g.classDefinition() else try g.output(),
            9 => if (top) try g.moduleDefinition() else try g.assignment(),
            10 => try g.beginRescue(),
            11 => try g.iteration(),
            12 => try g.multipleAssignment(),
            13 => try g.jump(),
            14 => try g.benchmark(),
            else => try g.modified(),
        }
    }

    fn body(g: *Generator) Error!void {
        g.nesting += 1;
        defer g.nesting -= 1;
        if (g.nesting > MAX_NESTING) {
            try g.newline();
            try g.emit("nil");
            return;
        }
        var n: usize = 0;
        while (n == 0 or (n < MAX_BODY and g.statements < MAX_STATEMENTS and !g.stop())) : (n += 1) try g.statement();
    }

    fn end(g: *Generator) Error!void {
        try g.newline();
        try g.emit("end");
    }

    fn assignment(g: *Generator) Error!void {
        const k = g.anyKind();
        const reuse = g.vars_len > g.scope_start and g.pick(3) == 0;
        if (reuse) {
            const slot = g.scope_start + g.pick(g.vars_len - g.scope_start);
            try g.emitf("{s} = ", .{g.vars[slot].name});
            try g.expression(k, 0);
            g.vars[slot].kind = k;
            return;
        }
        // A new variable exists after its value: reading it in the value would be nil.
        const index = @min(g.vars_len, MAX_VARS - 1);
        try g.emitf("{s} = ", .{VAR_NAMES[index]});
        try g.expression(k, 0);
        g.vars[g.newSlot()].kind = k;
    }

    /// A slot for a new variable, or the last one when they're all taken.
    fn newSlot(g: *Generator) usize {
        if (g.vars_len < MAX_VARS) {
            g.vars[g.vars_len] = .{ .name = VAR_NAMES[g.vars_len], .kind = .number };
            g.vars_len += 1;
        }
        return g.vars_len - 1;
    }

    fn output(g: *Generator) Error!void {
        try g.emit(if (g.pick(2) == 0) "puts(" else "inspect(");
        try g.expression(g.anyKind(), 0);
        try g.emit(")");
    }

    fn compoundAssignment(g: *Generator) Error!void {
        const slot = g.varOf(.number) orelse return g.assignment();
        const ops = [_][]const u8{ "+=", "-=", "*=", "||=" };
        try g.emitf("{s} {s} ", .{ g.vars[slot].name, ops[g.pick(ops.len)] });
        try g.expression(.number, 1);
    }

    fn ifStatement(g: *Generator) Error!void {
        try g.emit(if (g.pick(4) == 0) "unless " else "if ");
        try g.expression(.boolean, 1);
        try g.body();
        if (g.pick(2) == 1) {
            try g.newline();
            try g.emit("elsif ");
            try g.expression(.boolean, 1);
            try g.body();
        }
        if (g.pick(2) == 1) {
            try g.newline();
            try g.emit("else");
            try g.body();
        }
        try g.end();
    }

    fn whileLoop(g: *Generator) Error!void {
        // A counter makes it end however the body goes (a `next` before the count would not).
        const slot = g.newSlot();
        const counter = g.vars[slot].name;
        try g.emitf("{s} = 0", .{counter});
        try g.newline();
        try g.emitf("while {s} < {d}", .{ counter, 1 + g.pick(MAX_LOOP) });
        g.nesting += 1;
        try g.newline();
        try g.emitf("{s} += 1", .{counter});
        g.nesting -= 1;
        const outer = g.in_loop;
        g.in_loop = true;
        defer g.in_loop = outer;
        try g.body();
        try g.end();
    }

    fn forLoop(g: *Generator) Error!void {
        const slot = g.newSlot();
        g.vars[slot].kind = .number;
        try g.emitf("for {s} in ", .{g.vars[slot].name});
        try g.boundedCollection();
        const outer = g.in_loop;
        g.in_loop = true;
        defer g.in_loop = outer;
        try g.body();
        try g.end();
    }

    fn caseStatement(g: *Generator) Error!void {
        try g.emit("case ");
        try g.expression(.number, 1);
        const whens = 1 + g.pick(3);
        for (0..whens) |_| {
            try g.newline();
            switch (g.pick(3)) {
                0 => try g.emitf("when {d}", .{g.pick(5)}),
                1 => try g.emitf("when {d}, {d}", .{ g.pick(5), 5 + g.pick(5) }),
                else => try g.emitf("when {d}..{d}", .{ g.pick(5), 5 + g.pick(5) }),
            }
            try g.body();
        }
        if (g.pick(2) == 1) {
            try g.newline();
            try g.emit("else");
            try g.body();
        }
        try g.end();
    }

    fn methodDefinition(g: *Generator) Error!void {
        if (g.methods_len == MAX_METHODS) return g.output();
        const arity: u8 = @intCast(g.pick(PARAM_NAMES.len + 1));
        const name = METHOD_NAMES[g.methods_len];
        try g.emitf("def {s}", .{name});
        const saved_len = g.vars_len;
        const saved_start = g.scope_start;
        const outer = g.in_method;
        g.scope_start = g.vars_len;
        g.in_method = true;
        defer {
            g.vars_len = saved_len;
            g.scope_start = saved_start;
            g.in_method = outer;
        }
        if (arity > 0) {
            try g.emit("(");
            for (PARAM_NAMES[0..arity], 0..) |param, i| {
                if (i > 0) try g.emit(", ");
                try g.emit(param);
                g.addVar(param, .number);
            }
            try g.emit(")");
        }
        if (g.pick(3) == 0) {
            try g.emit(" = ");
            try g.expression(.number, 1);
        } else {
            try g.body();
            if (g.pick(2) == 1) {
                g.nesting += 1;
                try g.newline();
                try g.emit("yield(1) if block_given?");
                g.nesting -= 1;
            }
            try g.end();
        }
        g.methods[g.methods_len] = .{ .name = name, .arity = arity };
        g.methods_len += 1;
    }

    fn addVar(g: *Generator, name: []const u8, kind: Kind) void {
        if (g.vars_len == MAX_VARS) return;
        g.vars[g.vars_len] = .{ .name = name, .kind = kind };
        g.vars_len += 1;
    }

    fn classDefinition(g: *Generator) Error!void {
        if (g.classes_len == MAX_CLASSES) return g.output();
        const name = CLASS_NAMES[g.classes_len];
        const arity: u8 = @intCast(1 + g.pick(2));
        try g.emitf("class {s}", .{name});
        if (g.pick(3) == 0) try g.emit(" < Object");
        g.nesting += 1;
        try g.newline();
        try g.emit("attr_accessor :size");
        try g.newline();
        try g.emitf("@@made = {d}", .{g.pick(3)});
        try g.newline();
        try g.emitf("def initialize({s})", .{if (arity == 1) "a" else "a, b"});
        g.nesting += 1;
        try g.newline();
        try g.emit("@size = a");
        try g.newline();
        try g.emit("@@made += 1");
        g.nesting -= 1;
        try g.end();
        try g.newline();
        try g.emit("def grow(by = 1) = @size + by");
        try g.newline();
        try g.emit("def self.made = @@made");
        try g.newline();
        try g.emit("def to_s = \"#{@size}\"");
        g.nesting -= 1;
        try g.end();
        g.classes[g.classes_len] = .{ .name = name, .arity = arity };
        g.classes_len += 1;
    }

    fn moduleDefinition(g: *Generator) Error!void {
        try g.emitf("module Mod{d}", .{g.pick(2)});
        g.nesting += 1;
        try g.newline();
        try g.emit("LIMIT = ");
        try g.literal(.number);
        try g.newline();
        try g.emit("def self.limit = LIMIT");
        g.nesting -= 1;
        try g.end();
    }

    fn beginRescue(g: *Generator) Error!void {
        try g.emit("begin");
        try g.body();
        if (g.pick(2) == 1) {
            g.nesting += 1;
            try g.newline();
            const errors = [_][]const u8{ "raise(\"boom\")", "raise(ArgumentError, \"bad\")", "raise(TypeError)" };
            try g.emit(errors[g.pick(errors.len)]);
            g.nesting -= 1;
        }
        try g.newline();
        const clauses = [_][]const u8{ "rescue => e", "rescue ArgumentError, TypeError => e", "rescue RuntimeError" };
        try g.emit(clauses[g.pick(clauses.len)]);
        try g.body();
        if (g.pick(2) == 1) {
            try g.newline();
            try g.emit("ensure");
            try g.body();
        }
        try g.end();
    }

    fn iteration(g: *Generator) Error!void {
        try g.boundedCollection();
        const iterators = [_][]const u8{ ".each", ".map", ".filter", ".reject" };
        try g.emit(iterators[g.pick(iterators.len)]);
        try g.block(.number);
    }

    /// `do |x| ... end`, its parameter holding a `param_kind`, in a scope of its own.
    fn block(g: *Generator, param_kind: Kind) Error!void {
        const param = BLOCK_NAMES[@min(g.nesting, BLOCK_NAMES.len - 1)];
        try g.emitf(" do |{s}|", .{param});
        const saved_len = g.vars_len;
        defer g.vars_len = saved_len;
        g.addVar(param, param_kind);
        const outer = g.in_loop;
        g.in_loop = true; // `next` and `break` work in a block
        defer g.in_loop = outer;
        try g.body();
        try g.end();
    }

    fn multipleAssignment(g: *Generator) Error!void {
        const first = g.newSlot();
        const second = g.newSlot();
        try g.emitf("{s}, {s} = ", .{ g.vars[first].name, g.vars[second].name });
        try g.expression(.number, 1);
        try g.emit(", ");
        try g.expression(.string, 1);
        g.vars[first].kind = .number;
        g.vars[second].kind = .string;
    }

    /// `break`, `next` or `return` where one is allowed; an assignment elsewhere.
    fn jump(g: *Generator) Error!void {
        if (g.in_loop and g.pick(2) == 0) {
            try g.emit(if (g.pick(2) == 0) "next" else "break");
        } else if (g.in_method) {
            try g.emit("return ");
            try g.expression(.number, 1);
        } else try g.assignment();
        if (g.pick(2) == 1) {
            try g.emit(" if ");
            try g.expression(.boolean, 1);
        }
    }

    fn benchmark(g: *Generator) Error!void {
        try g.emit("benchmark(\"step\") do");
        try g.body();
        try g.end();
    }

    /// A statement with an `if` or `unless` modifier.
    fn modified(g: *Generator) Error!void {
        try g.output();
        try g.emit(if (g.pick(2) == 0) " if " else " unless ");
        try g.expression(.boolean, 1);
    }

    // --- Expressions ---

    fn anyKind(g: *Generator) Kind {
        return @fromBackingInt(@intCast(g.pick(@typeInfo(Kind).@"enum".field_names.len)));
    }

    fn varOf(g: *Generator, k: Kind) ?usize {
        var found: [MAX_VARS]usize = undefined;
        var n: usize = 0;
        for (g.vars[g.scope_start..g.vars_len], g.scope_start..) |v, i| {
            if (v.kind == k) {
                found[n] = i;
                n += 1;
            }
        }
        if (n == 0) return null;
        return found[g.pick(n)];
    }

    fn expression(g: *Generator, k: Kind, depth: usize) Error!void {
        if (depth >= MAX_DEPTH) return g.literal(k);
        const d = depth + 1;
        switch (g.pick(4)) {
            0 => return g.literal(k),
            1 => if (g.varOf(k)) |slot| return g.emit(g.vars[slot].name),
            2 => return g.ternary(k, d),
            else => {},
        }
        switch (k) {
            .number => try g.numberExpression(d),
            .string => try g.stringExpression(d),
            .boolean => try g.booleanExpression(d),
            .symbol => try g.literal(.symbol),
            .array => try g.arrayExpression(d),
            .map => try g.mapExpression(d),
            .range => try g.literal(.range),
            .solid => try g.solidExpression(d),
            .sketch => try g.sketchExpression(d),
        }
    }

    fn ternary(g: *Generator, k: Kind, d: usize) Error!void {
        try g.emit("(");
        try g.expression(.boolean, d);
        try g.emit(" ? ");
        try g.expression(k, d);
        try g.emit(" : ");
        try g.expression(k, d);
        try g.emit(")");
    }

    fn literal(g: *Generator, k: Kind) Error!void {
        switch (k) {
            .number => {
                const numbers = [_][]const u8{ "1", "0", "2.5", "-3", "1_000", "1e-3", "0.1", "7", "-0.5", "42" };
                try g.emit(numbers[g.pick(numbers.len)]);
            },
            .string => {
                const strings = [_][]const u8{ "\"a\"", "\"\"", "'raw \\\\ #{x}'", "\"tab\\tquote\\\" \\u00e9\"", "\"#{1 + 1}\"", "\"%d\"" };
                try g.emit(strings[g.pick(strings.len)]);
            },
            .boolean => try g.emit(if (g.pick(2) == 0) "true" else "false"),
            .symbol => {
                const symbols = [_][]const u8{ ":a", ":xy", ":\"with space\"", ":inch" };
                try g.emit(symbols[g.pick(symbols.len)]);
            },
            .array => {
                const arrays = [_][]const u8{ "[1, 2, 3]", "[]", "[[1, 2], [3]]", "[1, nil, \"a\"]", "%w[a b]" };
                try g.emit(arrays[g.pick(arrays.len)]);
            },
            .map => {
                const maps = [_][]const u8{ "{ a: 1, b: 2 }", "{}", "{ \"k\" => [1], n: nil }" };
                try g.emit(maps[g.pick(maps.len)]);
            },
            .range => try g.emitf("({d}{s}{d})", .{ g.pick(3), if (g.pick(2) == 0) ".." else "...", 1 + g.pick(MAX_LOOP) }),
            .solid => try g.emit("cube(1)"),
            .sketch => try g.emit("square(1, 1)"),
        }
    }

    /// An Array or Range literal small enough to loop over.
    fn boundedCollection(g: *Generator) Error!void {
        if (g.pick(2) == 0) return g.literal(.range);
        try g.emit("[");
        const n = 1 + g.pick(MAX_LOOP);
        for (0..n) |i| {
            if (i > 0) try g.emit(", ");
            try g.literal(.number);
        }
        try g.emit("]");
    }

    fn numberExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(7)) {
            0 => {
                const ops = [_][]const u8{ "+", "-", "*", "/", "%", "**", "&", "|", "<<" };
                try g.binary(.number, ops[g.pick(ops.len)], d);
            },
            1 => {
                try g.emit("-(");
                try g.expression(.number, d);
                try g.emit(")");
            },
            2 => try g.methodCall(.number, &number_class.methods, d),
            3 => {
                try g.emitf("Math.{s}(", .{math_class.methods[g.pick(math_class.methods.len)].name});
                try g.arguments(d);
                try g.emit(")");
            },
            4 => {
                try g.receiver(if (g.pick(2) == 0) .array else .string, d);
                try g.emit(".length");
            },
            5 => if (g.methods_len > 0) try g.callMethod(d) else try g.literal(.number),
            else => if (g.classes_len > 0) try g.useClass(d) else try g.literal(.number),
        }
    }

    fn stringExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(4)) {
            0 => {
                try g.emit("\"x#{");
                try g.expression(g.anyKind(), d);
                try g.emit("}y\"");
            },
            1 => try g.binary(.string, "+", d),
            2 => try g.methodCall(.string, &string_class.methods, d),
            else => {
                try g.receiver(.number, d);
                try g.emit(".to_s");
            },
        }
    }

    fn booleanExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(4)) {
            0 => {
                const ops = [_][]const u8{ "<", "<=", ">", ">=", "==", "!=" };
                try g.emit("(");
                try g.expression(.number, d);
                try g.emitf(" {s} ", .{ops[g.pick(ops.len)]});
                try g.expression(.number, d);
                try g.emit(")");
            },
            1 => try g.binary(.boolean, if (g.pick(2) == 0) "&&" else "||", d),
            2 => {
                try g.emit("!(");
                try g.expression(.boolean, d);
                try g.emit(")");
            },
            else => {
                try g.receiver(.array, d);
                try g.emit(".contains?(");
                try g.expression(.number, d);
                try g.emit(")");
            },
        }
    }

    fn arrayExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(4)) {
            0 => {
                try g.emit("[");
                const n = g.pick(4);
                for (0..n) |i| {
                    if (i > 0) try g.emit(", ");
                    try g.expression(g.anyKind(), d);
                }
                try g.emit("]");
            },
            1 => {
                try g.receiver(.array, d);
                try g.emit(if (g.pick(2) == 0) ".map { |x| x }" else ".filter { |x| x }");
            },
            2 => {
                try g.receiver(.range, d);
                try g.emit(".to_a");
            },
            else => try g.methodCall(.array, &array_class.methods, d),
        }
    }

    fn mapExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(2)) {
            0 => {
                try g.emit("{ key: ");
                try g.expression(g.anyKind(), d);
                try g.emit(", \"s\" => ");
                try g.expression(g.anyKind(), d);
                try g.emit(" }");
            },
            else => try g.methodCall(.map, &map_class.methods, d),
        }
    }

    fn solidExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(4)) {
            0 => try g.primitive(.primitive_3d, d),
            1 => try g.binary(.solid, if (g.pick(2) == 0) "+" else "-", d),
            2 => try g.shapeMethod(.solid, d),
            else => {
                try g.receiver(.sketch, d);
                try g.emit(".extrude(");
                try g.expression(.number, d);
                try g.emit(")");
            },
        }
    }

    fn sketchExpression(g: *Generator, d: usize) Error!void {
        switch (g.pick(2)) {
            0 => try g.primitive(.primitive_2d, d),
            else => try g.shapeMethod(.sketch, d),
        }
    }

    fn binary(g: *Generator, k: Kind, op: []const u8, d: usize) Error!void {
        try g.emit("(");
        try g.expression(k, d);
        try g.emitf(" {s} ", .{op});
        try g.expression(k, d);
        try g.emit(")");
    }

    /// An expression of kind `k` that a method call can follow: a name, or in parentheses.
    fn receiver(g: *Generator, k: Kind, d: usize) Error!void {
        if (g.varOf(k)) |slot| return g.emit(g.vars[slot].name);
        try g.emit("(");
        try g.expression(k, d);
        try g.emit(")");
    }

    /// A method from `table` on an expression of kind `k`, with arguments it may not take:
    /// the tables have names, not arities.
    fn methodCall(g: *Generator, k: Kind, table: []const common.MethodDef, d: usize) Error!void {
        try g.receiver(k, d);
        try g.emitf(".{s}", .{table[g.pick(table.len)].name});
        if (g.pick(3) == 0) return;
        try g.emit("(");
        try g.arguments(d);
        try g.emit(")");
        if (g.pick(4) == 0) try g.emit(" { |x| x }");
    }

    fn arguments(g: *Generator, d: usize) Error!void {
        const n = g.pick(3);
        for (0..n) |i| {
            if (i > 0) try g.emit(", ");
            try g.expression(if (g.pick(3) == 0) g.anyKind() else .number, d);
        }
    }

    fn callMethod(g: *Generator, d: usize) Error!void {
        const m = g.methods[g.pick(g.methods_len)];
        try g.emitf("{s}(", .{m.name});
        for (0..m.arity) |i| {
            if (i > 0) try g.emit(", ");
            try g.expression(.number, d);
        }
        try g.emit(")");
    }

    fn useClass(g: *Generator, d: usize) Error!void {
        const c = g.classes[g.pick(g.classes_len)];
        try g.emitf("{s}.new(", .{c.name});
        for (0..c.arity) |i| {
            if (i > 0) try g.emit(", ");
            try g.expression(.number, d);
        }
        try g.emit(if (g.pick(2) == 0) ").grow" else ").size");
    }

    /// A global from the manifest that makes a solid or a sketch, with numbers for its
    /// positional parameters or one of its keywords.
    fn primitive(g: *Generator, category: manifest.Category, d: usize) Error!void {
        var found: [manifest.global_functions.len]*const manifest.GlobalFunction = undefined;
        var n: usize = 0;
        for (&manifest.global_functions) |*f| {
            if (f.category == category and f.signature != null) {
                found[n] = f;
                n += 1;
            }
        }
        const f = found[g.pick(n)];
        try g.emitf("{s}(", .{f.name});
        if (std.mem.eql(u8, f.name, "text")) {
            try g.expression(.string, d);
        } else if (std.mem.eql(u8, f.name, "polygon")) {
            try g.emit("[[0, 0], [2, 0], [0, 2]]");
        } else if (std.mem.eql(u8, f.name, "polyhedron")) {
            try g.emit("[[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]]");
        } else try g.signatureArguments(f.signature.?, d);
        try g.emit(")");
    }

    /// A shape method from the manifest on a shape of kind `k`.
    fn shapeMethod(g: *Generator, k: Kind, d: usize) Error!void {
        const m = manifest.mesh_methods[g.pick(manifest.mesh_methods.len)];
        try g.receiver(k, d);
        try g.emitf(".{s}(", .{m.name});
        try g.signatureArguments(m.signature, d);
        try g.emit(")");
    }

    /// Numbers for some of `signature`'s positional parameters, or one of its keywords.
    fn signatureArguments(g: *Generator, signature: anytype, d: usize) Error!void {
        if (signature.keywords.len > 0 and g.pick(2) == 0) {
            try g.emitf("{s}: ", .{signature.keywords[g.pick(signature.keywords.len)]});
            return g.expression(.number, d);
        }
        const n = if (signature.positional.len == 0) 0 else 1 + g.pick(signature.positional.len);
        for (0..n) |i| {
            if (i > 0) try g.emit(", ");
            try g.expression(.number, d);
        }
    }
};
