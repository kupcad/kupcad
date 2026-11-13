//! A hashed grid over points for welding (RTCD §7.1.3, §12.1, docs/architecture.md §5.1):
//! each point goes into the cell its coordinates fall in, cells are chained through
//! `next`, and a query visits the cells its radius-box overlaps in a fixed order. With a
//! cell at least `2 · radius` wide a query box overlaps at most eight cells. The grid keeps
//! only indices; the caller keeps the points and tells the grid what they are.

const std = @import("std");
const vec = @import("../math/vec.zig");
const Vec3 = vec.Vec3;

pub const Error = error{
    OutOfMemory,
    /// A coordinate too large for the cell size: `x + cell == x` in `f64`, so the point
    /// could not be placed (the scale guard of diagnostics.zig catches this earlier).
    OutOfRange,
};

/// How much wider than twice the query radius a cell may be asked for, in rounding.
const CELL_SLACK: f64 = 1e-9;
/// Cells beyond this many from the origin overflow the cell index.
const MAX_CELL: f64 = 1e15;

const Cell = struct { x: i64, y: i64, z: i64 };

/// Hashes a cell, and compares them.
const CellContext = struct {
    pub fn hash(_: CellContext, c: Cell) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&c.x));
        h.update(std.mem.asBytes(&c.y));
        h.update(std.mem.asBytes(&c.z));
        return h.final();
    }
    pub fn eql(_: CellContext, a: Cell, b: Cell) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

pub const Grid = struct {
    cell: f64,
    /// The first item of each occupied cell.
    first: std.HashMapUnmanaged(Cell, u32, CellContext, std.hash_map.default_max_load_percentage) = .empty,
    /// The item after each item in its cell's chain; `NONE` ends a chain.
    next: std.ArrayList(u32) = .empty,
    /// The cell each item was placed in.
    cells: std.ArrayList(Cell) = .empty,

    pub const NONE: u32 = std.math.maxInt(u32);

    /// A grid whose cells are `cell` wide (at least twice the query radius).
    pub fn init(cell: f64) Grid {
        return .{ .cell = cell };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        self.first.deinit(allocator);
        self.next.deinit(allocator);
        self.cells.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Grid) usize {
        return self.next.items.len;
    }

    fn cellOf(self: *const Grid, p: Vec3) Error!Cell {
        var out: Cell = undefined;
        inline for (.{ "x", "y", "z" }, 0..) |name, k| {
            const scaled = @floor(p[k] / self.cell);
            if (!(scaled - scaled == 0) or @abs(scaled) >= MAX_CELL) return error.OutOfRange;
            @field(out, name) = @intFromFloat(scaled);
        }
        return out;
    }

    /// Places item `index` (the next one: `index == count()`) at `p`.
    pub fn insert(self: *Grid, allocator: std.mem.Allocator, index: u32, p: Vec3) Error!void {
        std.debug.assert(index == self.next.items.len);
        const cell = try self.cellOf(p);
        try self.next.ensureUnusedCapacity(allocator, 1);
        try self.cells.ensureUnusedCapacity(allocator, 1);
        const entry = try self.first.getOrPut(allocator, cell);
        if (!entry.found_existing) entry.value_ptr.* = NONE;
        // At the front of the chain: visited in reverse order of insertion, so a query
        // that wants the first kept item takes the minimum over the chain
        self.next.appendAssumeCapacity(entry.value_ptr.*);
        self.cells.appendAssumeCapacity(cell);
        entry.value_ptr.* = index;
    }

    /// Calls `visit(ctx, index)` for every item whose cell overlaps the box of radius
    /// `radius` about `p`, cells in a fixed order; `visit` returns false to stop. The
    /// caller tests the distance itself. A box wider than a cell is clamped to the eight
    /// neighbours, so `radius` must be at most half a cell.
    pub fn query(self: *const Grid, p: Vec3, radius: f64, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32) bool) Error!void {
        std.debug.assert(radius * 2.0 <= self.cell * (1.0 + CELL_SLACK));
        const lo = try self.cellOf(vec.sub(p, .{ radius, radius, radius }));
        const hi = try self.cellOf(vec.add(p, .{ radius, radius, radius }));
        var x = lo.x;
        while (x <= hi.x) : (x += 1) {
            var y = lo.y;
            while (y <= hi.y) : (y += 1) {
                var z = lo.z;
                while (z <= hi.z) : (z += 1) {
                    var item = self.first.get(.{ .x = x, .y = y, .z = z }) orelse NONE;
                    while (item != NONE) : (item = self.next.items[item]) {
                        if (!visit(ctx, item)) return;
                    }
                }
            }
        }
    }
};

/// Welds points: `find` gives the first kept point within `radius` of a query, `add`
/// keeps a new one, `atRadius` the first whose distance is `radius` to within `margin`
/// (neither clearly within it nor clearly beyond). Points are kept by the caller in
/// `points`; the grid indexes them.
pub const PointWelder = struct {
    grid: Grid,
    radius: f64,
    margin: f64 = 0,

    pub fn init(radius: f64) PointWelder {
        return .{ .grid = Grid.init(2.0 * radius), .radius = radius };
    }

    /// A welder whose `atRadius` looks `margin` past `radius`: its cells that much wider.
    pub fn initWithMargin(radius: f64, margin: f64) PointWelder {
        return .{ .grid = Grid.init(2.0 * (radius + margin)), .radius = radius, .margin = margin };
    }

    pub fn deinit(self: *PointWelder, allocator: std.mem.Allocator) void {
        self.grid.deinit(allocator);
    }

    const Search = struct {
        points: []const Vec3,
        p: Vec3,
        radius_sq: f64,
        best: u32 = Grid.NONE,

        fn visit(self: *Search, index: u32) bool {
            if (vec.distanceSq(self.points[index], self.p) <= self.radius_sq and index < self.best) self.best = index;
            return true;
        }
    };

    /// The index of the first kept point within `radius` of `p`, or null.
    pub fn find(self: *const PointWelder, points: []const Vec3, p: Vec3) Error!?u32 {
        var search = Search{ .points = points, .p = p, .radius_sq = self.radius * self.radius };
        try self.grid.query(p, self.radius, &search, Search.visit);
        return if (search.best == Grid.NONE) null else search.best;
    }

    const Edge = struct {
        points: []const Vec3,
        p: Vec3,
        radius: f64,
        margin: f64,
        best: u32 = Grid.NONE,

        fn visit(self: *Edge, index: u32) bool {
            const d = vec.distance(self.points[index], self.p);
            if (@abs(d - self.radius) <= self.margin and index < self.best) self.best = index;
            return true;
        }
    };

    /// The index of the first kept point whose distance from `p` is within `margin` of
    /// `radius`, or null.
    pub fn atRadius(self: *const PointWelder, points: []const Vec3, p: Vec3) Error!?u32 {
        var search = Edge{ .points = points, .p = p, .radius = self.radius, .margin = self.margin };
        try self.grid.query(p, self.radius + self.margin, &search, Edge.visit);
        return if (search.best == Grid.NONE) null else search.best;
    }

    /// Registers `points[index]`, the point just appended.
    pub fn add(self: *PointWelder, allocator: std.mem.Allocator, points: []const Vec3, index: u32) Error!void {
        try self.grid.insert(allocator, index, points[index]);
    }
};
