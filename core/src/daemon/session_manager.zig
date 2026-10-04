const std = @import("std");
const ScriptSession = @import("session.zig").ScriptSession;

const log = std.log.scoped(.session_manager);

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: std.AutoHashMapUnmanaged(u64, *ScriptSession) = .empty,
    lru_queue: std.ArrayListUnmanaged(u64) = .empty,
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
        new_session.* = try ScriptSession.init(self.allocator, self.io);

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

        // Evict if threshold is hit (safe because we hold the lock)
        if (self.sessions.count() >= self.max_sessions) {
            try self.evictLRU();
        }

        try self.sessions.put(self.allocator, session_id, new_session);
        try self.lru_queue.append(self.allocator, session_id);

        log.info("Initialized new session for {s} (ID: {x})", .{ canonical_path, session_id });
        return new_session;
    }

    pub fn markUsed(self: *SessionManager, session_id: u64) void {
        for (self.lru_queue.items, 0..) |id, i| {
            if (id == session_id) {
                _ = self.lru_queue.orderedRemove(i);
                self.lru_queue.append(self.allocator, session_id) catch |err| {
                    log.err("OOM appending to LRU queue: {}", .{err});
                };
                return;
            }
        }
    }

    pub fn evictLRU(self: *SessionManager) !void {
        if (self.lru_queue.items.len == 0) return;
        const evict_id = self.lru_queue.orderedRemove(0);

        if (self.sessions.fetchRemove(evict_id)) |kv| {
            log.info("Evicting LRU Session (ID: {x}) to free memory", .{evict_id});
            var session = kv.value;
            session.deinit();
            self.allocator.destroy(session);
        }
    }
};
