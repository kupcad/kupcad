//! Exact geometric predicates: the sign of `orient2d`, `incircle` and `orient3d` is always
//! right, however close the points are to degenerate. A port of Jonathan Shewchuk's
//! adaptive-precision predicates (`predicates.c`, public domain, 1996): each predicate
//! computes a floating-point estimate with an error bound and returns it when the sign is
//! certain; otherwise it re-computes with floating-point expansions (sums of doubles that
//! represent a value exactly) in stages, each stage reusing the last, until the sign is
//! certain. The expansion arithmetic needs round-to-nearest `f64` with no fused
//! multiply-add, which `@setFloatMode(.strict)` and the no-`@mulAdd` rule keep (architecture
//! §6, D6).
//!
//! Exactness assumes the arithmetic neither overflows nor underflows, down to the lowest
//! components of the expansions (about 2^-53 per factor below the products of two
//! (`orient2d`), three (`orient3d`) or four (`incircle`) coordinate differences), so
//! coordinates between about 1e-40 and 1e40 (model units, mm) are always safe. KupCAD's
//! size limits keep models far inside that.
//!
//! Costs: the certain cases are a few multiplications; the adaptive stages run only near
//! degeneracy, and the last (exact) stage of `incircle` is a few thousand operations.

const std = @import("std");

comptime {
    @setFloatMode(.strict);
}

/// 2^27 + 1: `split` multiplies by it to cut a double into two halves of 26 bits.
const SPLITTER: f64 = 134217729.0;
/// 2^-53, the largest relative error of a rounded `f64` operation.
const EPSILON: f64 = 1.1102230246251565e-16;

// The error bounds of the estimates (Shewchuk's, derived in the paper for each stage).
const RESULT_ERR_BOUND: f64 = (3.0 + 8.0 * EPSILON) * EPSILON;
const CCW_ERR_BOUND_A: f64 = (3.0 + 16.0 * EPSILON) * EPSILON;
const CCW_ERR_BOUND_B: f64 = (2.0 + 12.0 * EPSILON) * EPSILON;
const CCW_ERR_BOUND_C: f64 = (9.0 + 64.0 * EPSILON) * EPSILON * EPSILON;
const O3D_ERR_BOUND_A: f64 = (7.0 + 56.0 * EPSILON) * EPSILON;
const O3D_ERR_BOUND_B: f64 = (3.0 + 28.0 * EPSILON) * EPSILON;
const O3D_ERR_BOUND_C: f64 = (26.0 + 288.0 * EPSILON) * EPSILON * EPSILON;
const ICC_ERR_BOUND_A: f64 = (10.0 + 96.0 * EPSILON) * EPSILON;
const ICC_ERR_BOUND_B: f64 = (4.0 + 48.0 * EPSILON) * EPSILON;
const ICC_ERR_BOUND_C: f64 = (44.0 + 576.0 * EPSILON) * EPSILON * EPSILON;

/// A sum or product as the rounded result `hi` and the exact remainder `lo`: `hi + lo` is
/// the exact value.
const Pair = struct { hi: f64, lo: f64 };

/// `a + b` exactly, when `|a| >= |b|`.
inline fn fastTwoSum(a: f64, b: f64) Pair {
    const x = a + b;
    const bvirt = x - a;
    return .{ .hi = x, .lo = b - bvirt };
}

/// `a + b` exactly.
inline fn twoSum(a: f64, b: f64) Pair {
    const x = a + b;
    const bvirt = x - a;
    const avirt = x - bvirt;
    const bround = b - bvirt;
    const around = a - avirt;
    return .{ .hi = x, .lo = around + bround };
}

/// `a - b` exactly.
inline fn twoDiff(a: f64, b: f64) Pair {
    const x = a - b;
    return .{ .hi = x, .lo = twoDiffTail(a, b, x) };
}

/// The remainder of `a - b` given its rounded result `x`.
inline fn twoDiffTail(a: f64, b: f64, x: f64) f64 {
    const bvirt = a - x;
    const avirt = x + bvirt;
    const bround = bvirt - b;
    const around = a - avirt;
    return around + bround;
}

/// `a` as two non-overlapping halves of 26 bits each (Dekker's split).
inline fn split(a: f64) Pair {
    const c = SPLITTER * a;
    const abig = c - a;
    const hi = c - abig;
    return .{ .hi = hi, .lo = a - hi };
}

/// `a * b` exactly.
inline fn twoProduct(a: f64, b: f64) Pair {
    const x = a * b;
    const as = split(a);
    const bs = split(b);
    return .{ .hi = x, .lo = productTail(as, bs, x) };
}

/// `a * b` exactly, `b` split already.
inline fn twoProductPresplit(a: f64, b: f64, bs: Pair) Pair {
    const x = a * b;
    return .{ .hi = x, .lo = productTail(split(a), bs, x) };
}

inline fn productTail(as: Pair, bs: Pair, x: f64) f64 {
    const err1 = x - (as.hi * bs.hi);
    const err2 = err1 - (as.lo * bs.hi);
    const err3 = err2 - (as.hi * bs.lo);
    return (as.lo * bs.lo) - err3;
}

/// `a * a` exactly.
inline fn square(a: f64) Pair {
    const x = a * a;
    const as = split(a);
    const err1 = x - (as.hi * as.hi);
    const err3 = err1 - ((as.hi + as.hi) * as.lo);
    return .{ .hi = x, .lo = (as.lo * as.lo) - err3 };
}

/// `(a1 + a0) + b` as three components, least significant first.
inline fn twoOneSum(a1: f64, a0: f64, b: f64) [3]f64 {
    const i = twoSum(a0, b);
    const x = twoSum(a1, i.hi);
    return .{ i.lo, x.lo, x.hi };
}

/// `(a1 + a0) - b` as three components, least significant first.
inline fn twoOneDiff(a1: f64, a0: f64, b: f64) [3]f64 {
    const i = twoDiff(a0, b);
    const x = twoSum(a1, i.hi);
    return .{ i.lo, x.lo, x.hi };
}

/// `(a1 + a0) + (b1 + b0)` as a four-component expansion, least significant first.
inline fn twoTwoSum(a1: f64, a0: f64, b1: f64, b0: f64) [4]f64 {
    const j = twoOneSum(a1, a0, b0);
    const x = twoOneSum(j[2], j[1], b1);
    return .{ j[0], x[0], x[1], x[2] };
}

/// `(a1 + a0) - (b1 + b0)` as a four-component expansion, least significant first.
inline fn twoTwoDiff(a1: f64, a0: f64, b1: f64, b0: f64) [4]f64 {
    const j = twoOneDiff(a1, a0, b0);
    const x = twoOneDiff(j[2], j[1], b1);
    return .{ j[0], x[0], x[1], x[2] };
}

/// `(a1 + a0) * b` as a four-component expansion, least significant first.
inline fn twoOneProduct(a1: f64, a0: f64, b: f64) [4]f64 {
    const bs = split(b);
    const i = twoProductPresplit(a0, b, bs);
    const j = twoProductPresplit(a1, b, bs);
    const k = twoSum(i.hi, j.lo);
    const x = fastTwoSum(j.hi, k.hi);
    return .{ i.lo, k.lo, x.lo, x.hi };
}

/// The sum of the expansions `e` and `f` into `h`, zero components dropped; the number of
/// components written. `h` holds at least `e.len + f.len`.
fn expansionSum(e: []const f64, f: []const f64, h: []f64) usize {
    var eindex: usize = 0;
    var findex: usize = 0;
    var hindex: usize = 0;
    var enow = e[0];
    var fnow = f[0];
    var q: f64 = undefined;
    if ((fnow > enow) == (fnow > -enow)) {
        q = enow;
        eindex = 1;
        if (eindex < e.len) enow = e[eindex];
    } else {
        q = fnow;
        findex = 1;
        if (findex < f.len) fnow = f[findex];
    }
    if (eindex < e.len and findex < f.len) {
        var s: Pair = undefined;
        if ((fnow > enow) == (fnow > -enow)) {
            s = fastTwoSum(enow, q);
            eindex += 1;
            if (eindex < e.len) enow = e[eindex];
        } else {
            s = fastTwoSum(fnow, q);
            findex += 1;
            if (findex < f.len) fnow = f[findex];
        }
        q = s.hi;
        if (s.lo != 0.0) {
            h[hindex] = s.lo;
            hindex += 1;
        }
        while (eindex < e.len and findex < f.len) {
            if ((fnow > enow) == (fnow > -enow)) {
                s = twoSum(q, enow);
                eindex += 1;
                if (eindex < e.len) enow = e[eindex];
            } else {
                s = twoSum(q, fnow);
                findex += 1;
                if (findex < f.len) fnow = f[findex];
            }
            q = s.hi;
            if (s.lo != 0.0) {
                h[hindex] = s.lo;
                hindex += 1;
            }
        }
    }
    while (eindex < e.len) {
        const s = twoSum(q, enow);
        eindex += 1;
        if (eindex < e.len) enow = e[eindex];
        q = s.hi;
        if (s.lo != 0.0) {
            h[hindex] = s.lo;
            hindex += 1;
        }
    }
    while (findex < f.len) {
        const s = twoSum(q, fnow);
        findex += 1;
        if (findex < f.len) fnow = f[findex];
        q = s.hi;
        if (s.lo != 0.0) {
            h[hindex] = s.lo;
            hindex += 1;
        }
    }
    if (q != 0.0 or hindex == 0) {
        h[hindex] = q;
        hindex += 1;
    }
    return hindex;
}

/// The expansion `e` times `b` into `h`, zero components dropped; the number of components
/// written. `h` holds at least `2 * e.len`.
fn scaleExpansion(e: []const f64, b: f64, h: []f64) usize {
    const bs = split(b);
    var hindex: usize = 0;
    const first = twoProductPresplit(e[0], b, bs);
    var q = first.hi;
    if (first.lo != 0.0) {
        h[hindex] = first.lo;
        hindex += 1;
    }
    var eindex: usize = 1;
    while (eindex < e.len) : (eindex += 1) {
        const product = twoProductPresplit(e[eindex], b, bs);
        const sum = twoSum(q, product.lo);
        if (sum.lo != 0.0) {
            h[hindex] = sum.lo;
            hindex += 1;
        }
        const next = fastTwoSum(product.hi, sum.hi);
        q = next.hi;
        if (next.lo != 0.0) {
            h[hindex] = next.lo;
            hindex += 1;
        }
    }
    if (q != 0.0 or hindex == 0) {
        h[hindex] = q;
        hindex += 1;
    }
    return hindex;
}

/// The expansion's approximate value: its components summed.
fn estimate(e: []const f64) f64 {
    var q = e[0];
    for (e[1..]) |component| q += component;
    return q;
}

/// An expansion of up to `capacity` components, with its length.
fn Expansion(comptime capacity: usize) type {
    return struct {
        items: [capacity]f64 = undefined,
        len: usize = 0,

        const Self = @This();

        fn slice(self: *const Self) []const f64 {
            return self.items[0..self.len];
        }

        fn fromFour(components: [4]f64) Self {
            var self: Self = .{ .len = 4 };
            self.items[0..4].* = components;
            return self;
        }

        fn one(value: f64) Self {
            var self: Self = .{ .len = 1 };
            self.items[0] = value;
            return self;
        }

        fn sum(e: []const f64, f: []const f64) Self {
            var self: Self = .{};
            self.len = expansionSum(e, f, &self.items);
            return self;
        }

        fn scaled(e: []const f64, b: f64) Self {
            var self: Self = .{};
            self.len = scaleExpansion(e, b, &self.items);
            return self;
        }

        fn last(self: *const Self) f64 {
            return self.items[self.len - 1];
        }
    };
}

/// The running total of an adaptive stage: two buffers, the sum written into the other.
fn Accumulator(comptime capacity: usize) type {
    return struct {
        buffers: [2]Expansion(capacity),
        current: u1 = 0,

        const Self = @This();

        fn init(start: Expansion(capacity)) Self {
            return .{ .buffers = .{ start, .{} } };
        }

        fn add(self: *Self, term: []const f64) void {
            const other = self.current ^ 1;
            self.buffers[other].len = expansionSum(self.buffers[self.current].slice(), term, &self.buffers[other].items);
            self.current = other;
        }

        fn value(self: *const Self) f64 {
            return self.buffers[self.current].last();
        }
    };
}

// ---------------------------------------------------------------------------------------
// orient2d

/// Positive when `a`, `b`, `c` turn counter-clockwise, negative when clockwise, zero when
/// collinear: the sign of the determinant `| ax-cx ay-cy ; bx-cx by-cy |`, always exact
/// (the value is exact only when the quick estimate was certain).
pub fn orient2d(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    const detleft = (a[0] - c[0]) * (b[1] - c[1]);
    const detright = (a[1] - c[1]) * (b[0] - c[0]);
    const det = detleft - detright;
    var detsum: f64 = undefined;
    if (detleft > 0.0) {
        if (detright <= 0.0) return det;
        detsum = detleft + detright;
    } else if (detleft < 0.0) {
        if (detright >= 0.0) return det;
        detsum = -detleft - detright;
    } else {
        return det;
    }
    const errbound = CCW_ERR_BOUND_A * detsum;
    if (det >= errbound or -det >= errbound) return det;
    return orient2dAdapt(a, b, c, detsum);
}

fn orient2dAdapt(a: [2]f64, b: [2]f64, c: [2]f64, detsum: f64) f64 {
    const acx = a[0] - c[0];
    const bcx = b[0] - c[0];
    const acy = a[1] - c[1];
    const bcy = b[1] - c[1];

    const detleft = twoProduct(acx, bcy);
    const detright = twoProduct(acy, bcx);
    const bexp = twoTwoDiff(detleft.hi, detleft.lo, detright.hi, detright.lo);
    var det = estimate(&bexp);
    var errbound = CCW_ERR_BOUND_B * detsum;
    if (det >= errbound or -det >= errbound) return det;

    const acxtail = twoDiffTail(a[0], c[0], acx);
    const bcxtail = twoDiffTail(b[0], c[0], bcx);
    const acytail = twoDiffTail(a[1], c[1], acy);
    const bcytail = twoDiffTail(b[1], c[1], bcy);
    if (acxtail == 0.0 and acytail == 0.0 and bcxtail == 0.0 and bcytail == 0.0) return det;

    errbound = CCW_ERR_BOUND_C * detsum + RESULT_ERR_BOUND * @abs(det);
    det += (acx * bcytail + bcy * acxtail) - (acy * bcxtail + bcx * acytail);
    if (det >= errbound or -det >= errbound) return det;

    var s = twoProduct(acxtail, bcy);
    var t = twoProduct(acytail, bcx);
    var u = twoTwoDiff(s.hi, s.lo, t.hi, t.lo);
    const c1 = Expansion(8).sum(&bexp, &u);

    s = twoProduct(acx, bcytail);
    t = twoProduct(acy, bcxtail);
    u = twoTwoDiff(s.hi, s.lo, t.hi, t.lo);
    const c2 = Expansion(12).sum(c1.slice(), &u);

    s = twoProduct(acxtail, bcytail);
    t = twoProduct(acytail, bcxtail);
    u = twoTwoDiff(s.hi, s.lo, t.hi, t.lo);
    const d = Expansion(16).sum(c2.slice(), &u);
    return d.last();
}

// ---------------------------------------------------------------------------------------
// orient3d

/// Positive when `d` lies below the plane through `a`, `b`, `c` (the three seen
/// counter-clockwise from above), negative when above, zero when coplanar: the sign of the
/// 3×3 determinant of `a-d`, `b-d`, `c-d`, always exact.
pub fn orient3d(a: [3]f64, b: [3]f64, c: [3]f64, d: [3]f64) f64 {
    const adx = a[0] - d[0];
    const bdx = b[0] - d[0];
    const cdx = c[0] - d[0];
    const ady = a[1] - d[1];
    const bdy = b[1] - d[1];
    const cdy = c[1] - d[1];
    const adz = a[2] - d[2];
    const bdz = b[2] - d[2];
    const cdz = c[2] - d[2];

    const bdxcdy = bdx * cdy;
    const cdxbdy = cdx * bdy;
    const cdxady = cdx * ady;
    const adxcdy = adx * cdy;
    const adxbdy = adx * bdy;
    const bdxady = bdx * ady;

    const det = adz * (bdxcdy - cdxbdy) + bdz * (cdxady - adxcdy) + cdz * (adxbdy - bdxady);
    const permanent = (@abs(bdxcdy) + @abs(cdxbdy)) * @abs(adz) +
        (@abs(cdxady) + @abs(adxcdy)) * @abs(bdz) +
        (@abs(adxbdy) + @abs(bdxady)) * @abs(cdz);
    const errbound = O3D_ERR_BOUND_A * permanent;
    if (det > errbound or -det > errbound) return det;
    return orient3dAdapt(a, b, c, d, permanent);
}

/// The products of one point's tails with the others' coordinates (`at_b`, `at_c` and the
/// like of the C): up to four components.
fn tailProducts(xtail: f64, ytail: f64, px: f64, py: f64, qx: f64, qy: f64) [2]Expansion(4) {
    // The first: xtail·py − ytail·px; the second: ytail·qx − xtail·qy.
    if (xtail == 0.0) {
        if (ytail == 0.0) return .{ Expansion(4).one(0.0), Expansion(4).one(0.0) };
        const first = twoProduct(-ytail, px);
        const second = twoProduct(ytail, qx);
        var f: Expansion(4) = .{ .len = 2 };
        f.items[0] = first.lo;
        f.items[1] = first.hi;
        var s: Expansion(4) = .{ .len = 2 };
        s.items[0] = second.lo;
        s.items[1] = second.hi;
        return .{ f, s };
    }
    if (ytail == 0.0) {
        const first = twoProduct(xtail, py);
        const second = twoProduct(-xtail, qy);
        var f: Expansion(4) = .{ .len = 2 };
        f.items[0] = first.lo;
        f.items[1] = first.hi;
        var s: Expansion(4) = .{ .len = 2 };
        s.items[0] = second.lo;
        s.items[1] = second.hi;
        return .{ f, s };
    }
    const xp = twoProduct(xtail, py);
    const yp = twoProduct(ytail, px);
    const yq = twoProduct(ytail, qx);
    const xq = twoProduct(xtail, qy);
    return .{
        Expansion(4).fromFour(twoTwoDiff(xp.hi, xp.lo, yp.hi, yp.lo)),
        Expansion(4).fromFour(twoTwoDiff(yq.hi, yq.lo, xq.hi, xq.lo)),
    };
}

fn orient3dAdapt(a: [3]f64, b: [3]f64, c: [3]f64, d: [3]f64, permanent: f64) f64 {
    const adx = a[0] - d[0];
    const bdx = b[0] - d[0];
    const cdx = c[0] - d[0];
    const ady = a[1] - d[1];
    const bdy = b[1] - d[1];
    const cdy = c[1] - d[1];
    const adz = a[2] - d[2];
    const bdz = b[2] - d[2];
    const cdz = c[2] - d[2];

    var p = twoProduct(bdx, cdy);
    var q = twoProduct(cdx, bdy);
    const bc = twoTwoDiff(p.hi, p.lo, q.hi, q.lo);
    const adet = Expansion(8).scaled(&bc, adz);

    p = twoProduct(cdx, ady);
    q = twoProduct(adx, cdy);
    const ca = twoTwoDiff(p.hi, p.lo, q.hi, q.lo);
    const bdet = Expansion(8).scaled(&ca, bdz);

    p = twoProduct(adx, bdy);
    q = twoProduct(bdx, ady);
    const ab = twoTwoDiff(p.hi, p.lo, q.hi, q.lo);
    const cdet = Expansion(8).scaled(&ab, cdz);

    const abdet = Expansion(16).sum(adet.slice(), bdet.slice());
    var fin = Accumulator(192).init(Expansion(192).sum(abdet.slice(), cdet.slice()));

    var det = estimate(fin.buffers[fin.current].slice());
    var errbound = O3D_ERR_BOUND_B * permanent;
    if (det >= errbound or -det >= errbound) return det;

    const adxtail = twoDiffTail(a[0], d[0], adx);
    const bdxtail = twoDiffTail(b[0], d[0], bdx);
    const cdxtail = twoDiffTail(c[0], d[0], cdx);
    const adytail = twoDiffTail(a[1], d[1], ady);
    const bdytail = twoDiffTail(b[1], d[1], bdy);
    const cdytail = twoDiffTail(c[1], d[1], cdy);
    const adztail = twoDiffTail(a[2], d[2], adz);
    const bdztail = twoDiffTail(b[2], d[2], bdz);
    const cdztail = twoDiffTail(c[2], d[2], cdz);
    if (adxtail == 0.0 and bdxtail == 0.0 and cdxtail == 0.0 and
        adytail == 0.0 and bdytail == 0.0 and cdytail == 0.0 and
        adztail == 0.0 and bdztail == 0.0 and cdztail == 0.0) return det;

    errbound = O3D_ERR_BOUND_C * permanent + RESULT_ERR_BOUND * @abs(det);
    det += (adz * ((bdx * cdytail + cdy * bdxtail) - (bdy * cdxtail + cdx * bdytail)) + adztail * (bdx * cdy - bdy * cdx)) +
        (bdz * ((cdx * adytail + ady * cdxtail) - (cdy * adxtail + adx * cdytail)) + bdztail * (cdx * ady - cdy * adx)) +
        (cdz * ((adx * bdytail + bdy * adxtail) - (ady * bdxtail + bdx * adytail)) + cdztail * (adx * bdy - ady * bdx));
    if (det >= errbound or -det >= errbound) return det;

    const at = tailProducts(adxtail, adytail, bdx, bdy, cdx, cdy); // at_b, at_c
    const bt = tailProducts(bdxtail, bdytail, cdx, cdy, adx, ady); // bt_c, bt_a
    const ct = tailProducts(cdxtail, cdytail, adx, ady, bdx, bdy); // ct_a, ct_b

    const bct = Expansion(8).sum(bt[0].slice(), ct[1].slice());
    fin.add(Expansion(16).scaled(bct.slice(), adz).slice());
    const cat = Expansion(8).sum(ct[0].slice(), at[1].slice());
    fin.add(Expansion(16).scaled(cat.slice(), bdz).slice());
    const abt = Expansion(8).sum(at[0].slice(), bt[1].slice());
    fin.add(Expansion(16).scaled(abt.slice(), cdz).slice());

    if (adztail != 0.0) fin.add(Expansion(8).scaled(&bc, adztail).slice());
    if (bdztail != 0.0) fin.add(Expansion(8).scaled(&ca, bdztail).slice());
    if (cdztail != 0.0) fin.add(Expansion(8).scaled(&ab, cdztail).slice());

    if (adxtail != 0.0) {
        if (bdytail != 0.0) {
            const pr = twoProduct(adxtail, bdytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, cdz));
            if (cdztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, cdztail));
        }
        if (cdytail != 0.0) {
            const pr = twoProduct(-adxtail, cdytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, bdz));
            if (bdztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, bdztail));
        }
    }
    if (bdxtail != 0.0) {
        if (cdytail != 0.0) {
            const pr = twoProduct(bdxtail, cdytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, adz));
            if (adztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, adztail));
        }
        if (adytail != 0.0) {
            const pr = twoProduct(-bdxtail, adytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, cdz));
            if (cdztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, cdztail));
        }
    }
    if (cdxtail != 0.0) {
        if (adytail != 0.0) {
            const pr = twoProduct(cdxtail, adytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, bdz));
            if (bdztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, bdztail));
        }
        if (bdytail != 0.0) {
            const pr = twoProduct(-cdxtail, bdytail);
            fin.add(&twoOneProduct(pr.hi, pr.lo, adz));
            if (adztail != 0.0) fin.add(&twoOneProduct(pr.hi, pr.lo, adztail));
        }
    }

    if (adztail != 0.0) fin.add(Expansion(16).scaled(bct.slice(), adztail).slice());
    if (bdztail != 0.0) fin.add(Expansion(16).scaled(cat.slice(), bdztail).slice());
    if (cdztail != 0.0) fin.add(Expansion(16).scaled(abt.slice(), cdztail).slice());

    return fin.value();
}

// ---------------------------------------------------------------------------------------
// incircle

/// Positive when `d` lies inside the circle through `a`, `b`, `c` (given counter-clockwise),
/// negative when outside, zero when on it, always exact. With `a`, `b`, `c` clockwise the
/// sign is reversed.
pub fn incircle(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) f64 {
    const adx = a[0] - d[0];
    const bdx = b[0] - d[0];
    const cdx = c[0] - d[0];
    const ady = a[1] - d[1];
    const bdy = b[1] - d[1];
    const cdy = c[1] - d[1];

    const bdxcdy = bdx * cdy;
    const cdxbdy = cdx * bdy;
    const alift = adx * adx + ady * ady;
    const cdxady = cdx * ady;
    const adxcdy = adx * cdy;
    const blift = bdx * bdx + bdy * bdy;
    const adxbdy = adx * bdy;
    const bdxady = bdx * ady;
    const clift = cdx * cdx + cdy * cdy;

    const det = alift * (bdxcdy - cdxbdy) + blift * (cdxady - adxcdy) + clift * (adxbdy - bdxady);
    const permanent = (@abs(bdxcdy) + @abs(cdxbdy)) * alift +
        (@abs(cdxady) + @abs(adxcdy)) * blift +
        (@abs(adxbdy) + @abs(bdxady)) * clift;
    const errbound = ICC_ERR_BOUND_A * permanent;
    if (det > errbound or -det > errbound) return det;
    return incircleAdapt(a, b, c, d, permanent);
}

/// `x² + y²` as a four-component expansion.
fn lift(x: f64, y: f64) [4]f64 {
    const xx = square(x);
    const yy = square(y);
    return twoTwoSum(xx.hi, xx.lo, yy.hi, yy.lo);
}

/// The 2D cross product `px·qy − qx·py` as a four-component expansion.
fn crossExpansion(px: f64, py: f64, qx: f64, qy: f64) [4]f64 {
    const p = twoProduct(px, qy);
    const q = twoProduct(qx, py);
    return twoTwoDiff(p.hi, p.lo, q.hi, q.lo);
}

/// One point's contribution `(x² + y²) · cross` as an expansion of up to 32 components.
fn liftedCross(cross: *const [4]f64, x: f64, y: f64) Expansion(32) {
    const xc = Expansion(8).scaled(cross, x);
    const xxc = Expansion(16).scaled(xc.slice(), x);
    const yc = Expansion(8).scaled(cross, y);
    const yyc = Expansion(16).scaled(yc.slice(), y);
    return Expansion(32).sum(xxc.slice(), yyc.slice());
}

/// The `bct`, `bctt` pair of the C (and `cat`/`catt`, `abt`/`abtt`): the cross products of
/// two points' tails with their coordinates.
const TailCross = struct { first: Expansion(8), second: Expansion(4) };

fn tailCross(pxtail: f64, pytail: f64, px: f64, py: f64, qxtail: f64, qytail: f64, qx: f64, qy: f64) TailCross {
    var ti = twoProduct(pxtail, qy);
    var tj = twoProduct(px, qytail);
    const u = twoTwoSum(ti.hi, ti.lo, tj.hi, tj.lo);
    ti = twoProduct(qxtail, -py);
    tj = twoProduct(qx, -pytail);
    const v = twoTwoSum(ti.hi, ti.lo, tj.hi, tj.lo);
    ti = twoProduct(pxtail, qytail);
    tj = twoProduct(qxtail, pytail);
    return .{
        .first = Expansion(8).sum(&u, &v),
        .second = Expansion(4).fromFour(twoTwoDiff(ti.hi, ti.lo, tj.hi, tj.lo)),
    };
}

fn incircleAdapt(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64, permanent: f64) f64 {
    const adx = a[0] - d[0];
    const bdx = b[0] - d[0];
    const cdx = c[0] - d[0];
    const ady = a[1] - d[1];
    const bdy = b[1] - d[1];
    const cdy = c[1] - d[1];

    const bc = crossExpansion(bdx, bdy, cdx, cdy);
    const adet = liftedCross(&bc, adx, ady);
    const ca = crossExpansion(cdx, cdy, adx, ady);
    const bdet = liftedCross(&ca, bdx, bdy);
    const ab = crossExpansion(adx, ady, bdx, bdy);
    const cdet = liftedCross(&ab, cdx, cdy);

    const abdet = Expansion(64).sum(adet.slice(), bdet.slice());
    var fin = Accumulator(1152).init(Expansion(1152).sum(abdet.slice(), cdet.slice()));

    var det = estimate(fin.buffers[fin.current].slice());
    var errbound = ICC_ERR_BOUND_B * permanent;
    if (det >= errbound or -det >= errbound) return det;

    const adxtail = twoDiffTail(a[0], d[0], adx);
    const adytail = twoDiffTail(a[1], d[1], ady);
    const bdxtail = twoDiffTail(b[0], d[0], bdx);
    const bdytail = twoDiffTail(b[1], d[1], bdy);
    const cdxtail = twoDiffTail(c[0], d[0], cdx);
    const cdytail = twoDiffTail(c[1], d[1], cdy);
    if (adxtail == 0.0 and bdxtail == 0.0 and cdxtail == 0.0 and
        adytail == 0.0 and bdytail == 0.0 and cdytail == 0.0) return det;

    errbound = ICC_ERR_BOUND_C * permanent + RESULT_ERR_BOUND * @abs(det);
    det += ((adx * adx + ady * ady) * ((bdx * cdytail + cdy * bdxtail) - (bdy * cdxtail + cdx * bdytail)) +
        2.0 * (adx * adxtail + ady * adytail) * (bdx * cdy - bdy * cdx)) +
        ((bdx * bdx + bdy * bdy) * ((cdx * adytail + ady * cdxtail) - (cdy * adxtail + adx * cdytail)) +
            2.0 * (bdx * bdxtail + bdy * bdytail) * (cdx * ady - cdy * adx)) +
        ((cdx * cdx + cdy * cdy) * ((adx * bdytail + bdy * adxtail) - (ady * bdxtail + bdx * adytail)) +
            2.0 * (cdx * cdxtail + cdy * cdytail) * (adx * bdy - ady * bdx));
    if (det >= errbound or -det >= errbound) return det;

    const a_moves = adxtail != 0.0 or adytail != 0.0;
    const b_moves = bdxtail != 0.0 or bdytail != 0.0;
    const c_moves = cdxtail != 0.0 or cdytail != 0.0;
    const aa: [4]f64 = if (b_moves or c_moves) lift(adx, ady) else undefined;
    const bb: [4]f64 = if (c_moves or a_moves) lift(bdx, bdy) else undefined;
    const cc: [4]f64 = if (a_moves or b_moves) lift(cdx, cdy) else undefined;

    // The first-order terms of each tail: `tail · (2x · cross + lift_q · other_y − lift_p · other_y')`.
    var axtbc: Expansion(8) = undefined;
    var aytbc: Expansion(8) = undefined;
    var bxtca: Expansion(8) = undefined;
    var bytca: Expansion(8) = undefined;
    var cxtab: Expansion(8) = undefined;
    var cytab: Expansion(8) = undefined;
    if (adxtail != 0.0) {
        axtbc = Expansion(8).scaled(&bc, adxtail);
        firstOrder(&fin, &axtbc, 2.0 * adx, &cc, adxtail, bdy, &bb, -cdy);
    }
    if (adytail != 0.0) {
        aytbc = Expansion(8).scaled(&bc, adytail);
        firstOrder(&fin, &aytbc, 2.0 * ady, &bb, adytail, cdx, &cc, -bdx);
    }
    if (bdxtail != 0.0) {
        bxtca = Expansion(8).scaled(&ca, bdxtail);
        firstOrder(&fin, &bxtca, 2.0 * bdx, &aa, bdxtail, cdy, &cc, -ady);
    }
    if (bdytail != 0.0) {
        bytca = Expansion(8).scaled(&ca, bdytail);
        firstOrder(&fin, &bytca, 2.0 * bdy, &cc, bdytail, adx, &aa, -cdx);
    }
    if (cdxtail != 0.0) {
        cxtab = Expansion(8).scaled(&ab, cdxtail);
        firstOrder(&fin, &cxtab, 2.0 * cdx, &bb, cdxtail, ady, &aa, -bdy);
    }
    if (cdytail != 0.0) {
        cytab = Expansion(8).scaled(&ab, cdytail);
        firstOrder(&fin, &cytab, 2.0 * cdy, &aa, cdytail, bdx, &bb, -adx);
    }

    if (a_moves) {
        const t: TailCross = if (b_moves or c_moves)
            tailCross(bdxtail, bdytail, bdx, bdy, cdxtail, cdytail, cdx, cdy)
        else
            .{ .first = Expansion(8).one(0.0), .second = Expansion(4).one(0.0) };
        if (adxtail != 0.0) {
            secondOrder(&fin, &axtbc, adxtail, &t, 2.0 * adx);
            if (bdytail != 0.0) crossTail(&fin, &cc, adxtail, bdytail);
            if (cdytail != 0.0) crossTail(&fin, &bb, -adxtail, cdytail);
            thirdOrder(&fin, &t, adxtail, 2.0 * adx);
        }
        if (adytail != 0.0) {
            secondOrder(&fin, &aytbc, adytail, &t, 2.0 * ady);
            thirdOrder(&fin, &t, adytail, 2.0 * ady);
        }
    }
    if (b_moves) {
        const t: TailCross = if (c_moves or a_moves)
            tailCross(cdxtail, cdytail, cdx, cdy, adxtail, adytail, adx, ady)
        else
            .{ .first = Expansion(8).one(0.0), .second = Expansion(4).one(0.0) };
        if (bdxtail != 0.0) {
            secondOrder(&fin, &bxtca, bdxtail, &t, 2.0 * bdx);
            if (cdytail != 0.0) crossTail(&fin, &aa, bdxtail, cdytail);
            if (adytail != 0.0) crossTail(&fin, &cc, -bdxtail, adytail);
            thirdOrder(&fin, &t, bdxtail, 2.0 * bdx);
        }
        if (bdytail != 0.0) {
            secondOrder(&fin, &bytca, bdytail, &t, 2.0 * bdy);
            thirdOrder(&fin, &t, bdytail, 2.0 * bdy);
        }
    }
    if (c_moves) {
        const t: TailCross = if (a_moves or b_moves)
            tailCross(adxtail, adytail, adx, ady, bdxtail, bdytail, bdx, bdy)
        else
            .{ .first = Expansion(8).one(0.0), .second = Expansion(4).one(0.0) };
        if (cdxtail != 0.0) {
            secondOrder(&fin, &cxtab, cdxtail, &t, 2.0 * cdx);
            if (adytail != 0.0) crossTail(&fin, &bb, cdxtail, adytail);
            if (bdytail != 0.0) crossTail(&fin, &aa, -cdxtail, bdytail);
            thirdOrder(&fin, &t, cdxtail, 2.0 * cdx);
        }
        if (cdytail != 0.0) {
            secondOrder(&fin, &cytab, cdytail, &t, 2.0 * cdy);
            thirdOrder(&fin, &t, cdytail, 2.0 * cdy);
        }
    }

    return fin.value();
}

/// Adds `xtbc · twice + (lift_a · tail) · s_a + (lift_b · tail) · s_b` to `fin`.
fn firstOrder(fin: *Accumulator(1152), xtbc: *const Expansion(8), twice: f64, lift_a: *const [4]f64, tail: f64, s_a: f64, lift_b: *const [4]f64, s_b: f64) void {
    const temp16a = Expansion(16).scaled(xtbc.slice(), twice);
    const xta = Expansion(8).scaled(lift_a, tail);
    const temp16b = Expansion(16).scaled(xta.slice(), s_a);
    const xtb = Expansion(8).scaled(lift_b, tail);
    const temp16c = Expansion(16).scaled(xtb.slice(), s_b);
    const temp32a = Expansion(32).sum(temp16a.slice(), temp16b.slice());
    const temp48 = Expansion(48).sum(temp16c.slice(), temp32a.slice());
    fin.add(temp48.slice());
}

/// Adds `xtbc · tail + (t.first · tail) · twice` to `fin`.
fn secondOrder(fin: *Accumulator(1152), xtbc: *const Expansion(8), tail: f64, t: *const TailCross, twice: f64) void {
    const temp16a = Expansion(16).scaled(xtbc.slice(), tail);
    const xtbct = Expansion(16).scaled(t.first.slice(), tail);
    const temp32a = Expansion(32).scaled(xtbct.slice(), twice);
    const temp48 = Expansion(48).sum(temp16a.slice(), temp32a.slice());
    fin.add(temp48.slice());
}

/// Adds `(lift · tail_x) · tail_y` to `fin`.
fn crossTail(fin: *Accumulator(1152), lift_q: *const [4]f64, tail_x: f64, tail_y: f64) void {
    const temp8 = Expansion(8).scaled(lift_q, tail_x);
    const temp16a = Expansion(16).scaled(temp8.slice(), tail_y);
    fin.add(temp16a.slice());
}

/// Adds `(t.first · tail) · tail + (t.second · tail) · (twice + tail)` to `fin`.
fn thirdOrder(fin: *Accumulator(1152), t: *const TailCross, tail: f64, twice: f64) void {
    const xtbct = Expansion(16).scaled(t.first.slice(), tail);
    const temp32a = Expansion(32).scaled(xtbct.slice(), tail);
    const xtbctt = Expansion(8).scaled(t.second.slice(), tail);
    const temp16a = Expansion(16).scaled(xtbctt.slice(), twice);
    const temp16b = Expansion(16).scaled(xtbctt.slice(), tail);
    const temp32b = Expansion(32).sum(temp16a.slice(), temp16b.slice());
    const temp64 = Expansion(64).sum(temp32a.slice(), temp32b.slice());
    fin.add(temp64.slice());
}
