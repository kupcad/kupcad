//! `SessionManager`: keeps a `ScriptSession` per script (keyed by its canonical path), evicts
//! the least recently used past a limit and never one that is pinned by a `SessionLease`.
//! Used by `kupcad watch` and `kupcad build`.

const std = @import("std");
const ScriptSession = @import("session.zig").ScriptSession;

const log = std.log.scoped(.session_manager);

/// A pinned reference to a session. While a lease is outstanding the session is never evicted,
/// so the raw pointer stays valid. Return it with `SessionManager.release`.
pub const SessionLease = struct {
    id: u64,
    session: *ScriptSession,
};

/// Ownership model:
/// - The manager owns every `ScriptSession` and destroys them on eviction / deinit.
/// - `getOrInitializeSession` returns an UNPINNED pointer: it is only valid until the next call
///   that may evict (another `getOrInitializeSession`/`acquireSession` for a different path).
/// - Long-lived holders (watchers, daemons, other threads) must use `acquireSession`, which
///   refcounts the session; `evictLRU` skips pinned sessions so it can never free one in use.
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: std.AutoHashMapUnmanaged(u64, *ScriptSession) = .empty,
    lru_queue: std.ArrayList(u64) = .empty,
    /// Session id -> number of outstanding leases. Absent means unpinned.
    pins: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    max_sessions: usize,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_sessions: usize) SessionManager {
        return .{
            .allocator = allocator,
            .io = io,
            .max_sessions = max_sessions,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.lru_queue.deinit(self.allocator);
        self.pins.deinit(self.allocator);
    }

    /// Like `getOrInitializeSession`, but pins the session so eviction cannot free it while held.
    pub fn acquireSession(self: *SessionManager, path: []const u8) !SessionLease {
        const id = try self.sessionId(path);
        // Loop: an unpinned session can be evicted between creation and pinning by a racing
        // thread; retry until we pin the instance that is actually in the map.
        while (true) {
            const session = try self.getOrInitializeSession(path);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const current = self.sessions.get(id) orelse continue;
            if (current != session) continue;
            const gop = try self.pins.getOrPut(self.allocator, id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            return .{ .id = id, .session = session };
        }
    }

    /// Drops a lease obtained from `acquireSession`.
    pub fn release(self: *SessionManager, lease: SessionLease) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pins.getPtr(lease.id)) |count| {
            count.* -= 1;
            if (count.* == 0) _ = self.pins.remove(lease.id);
        }
    }

    pub fn isPinned(self: *const SessionManager, session_id: u64) bool {
        return self.pins.contains(session_id);
    }

    fn sessionId(self: *SessionManager, path: []const u8) !u64 {
        const canonical_path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        defer self.allocator.free(canonical_path);
        // Must match the keying in getOrInitializeSession.
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(canonical_path);
        return hasher.final();
    }

    /// Canonical Session Keying: Resolves absolute paths and Wyhashes them for secure O(1) lookup
    pub fn getOrInitializeSession(self: *SessionManager, path: []const u8) !*ScriptSession {
        const cwd = std.Io.Dir.cwd();

        const canonical_path = try cwd.realPathFileAlloc(self.io, path, self.allocator);
        defer self.allocator.free(canonical_path);

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(canonical_path);
        const session_id = hasher.final();

        // 1st Check: Fast path (Read-only lock)
        self.mutex.lockUncancelable(self.io);
        if (self.sessions.get(session_id)) |session| {
            self.markUsed(session_id);
            self.mutex.unlock(self.io);
            return session;
        }
        self.mutex.unlock(self.io);

        // Heavy Allocation (Occurs OUTSIDE the critical section to prevent stalling other threads)
        const new_session = try self.allocator.create(ScriptSession);
        errdefer self.allocator.destroy(new_session);
        new_session.* = try ScriptSession.init(self.allocator, self.io);
        errdefer new_session.deinit();

        // 2nd Check: Acquire lock for mutation
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Did another thread build the session while we were allocating?
        if (self.sessions.get(session_id)) |session| {
            self.markUsed(session_id);
            new_session.deinit();
            self.allocator.destroy(new_session);
            return session;
        }

        // Room in both first: a session in the map but not in the queue could never be
        // evicted, and one in neither leaked (the session was lost on a failed insert).
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.lru_queue.ensureUnusedCapacity(self.allocator, 1);

        // Evict if threshold is hit (safe because we hold the lock)
        if (self.sessions.count() >= self.max_sessions) self.evictLRU();

        self.sessions.putAssumeCapacityNoClobber(session_id, new_session);
        self.lru_queue.appendAssumeCapacity(session_id);

        log.info("Initialized new session for {s} (ID: {x})", .{ canonical_path, session_id });
        return new_session;
    }

    /// Moves `session_id` to the most recently used end of the queue, in place: removing
    /// and appending it again could fail to allocate and drop it from the queue for good.
    pub fn markUsed(self: *SessionManager, session_id: u64) void {
        const items = self.lru_queue.items;
        const i = std.mem.findScalar(u64, items, session_id) orelse return;
        std.mem.rotate(u64, items[i..], 1);
    }

    /// Evicts the least recently used session that is NOT pinned. Caller must hold `mutex`.
    /// If every session is pinned, nothing is evicted and the cache temporarily exceeds
    /// `max_sessions` (a soft limit) rather than freeing memory someone still uses.
    pub fn evictLRU(self: *SessionManager) void {
        var idx: usize = 0;
        while (idx < self.lru_queue.items.len and self.isPinned(self.lru_queue.items[idx])) idx += 1;
        if (idx == self.lru_queue.items.len) {
            if (idx > 0) log.warn("All {d} sessions are in use; exceeding max_sessions", .{idx});
            return;
        }
        const evict_id = self.lru_queue.orderedRemove(idx);

        if (self.sessions.fetchRemove(evict_id)) |kv| {
            log.info("Evicting LRU Session (ID: {x}) to free memory", .{evict_id});
            var session = kv.value;
            session.deinit();
            self.allocator.destroy(session);
        }
    }
};
