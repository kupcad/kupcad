const std = @import("std");
const ScriptSession = @import("session.zig").ScriptSession;

const log = std.log.scoped(.session_manager);

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMapUnmanaged(u64, *ScriptSession) = .empty,
    lru_queue: std.ArrayListUnmanaged(u64) = .empty,
    max_sessions: usize,

    pub fn init(allocator: std.mem.Allocator, max_sessions: usize) SessionManager {
        return .{
            .allocator = allocator,
            .max_sessions = max_sessions,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.lru_queue.deinit(self.allocator);
    }

    /// Canonical Session Keying: Resolves absolute paths and Wyhashes them for secure O(1) lookup
    pub fn getOrInitializeSession(self: *SessionManager, path: []const u8, io: std.Io) !*ScriptSession {
        const cwd = std.Io.Dir.cwd();

        // Use Zig 0.16.0's std.Io pattern for absolute path resolution
        const canonical_path = try cwd.realPathFileAlloc(io, path, self.allocator);
        defer self.allocator.free(canonical_path);

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(canonical_path);
        const session_id = hasher.final();

        if (self.sessions.get(session_id)) |session| {
            self.markUsed(session_id);
            return session;
        }

        // LRU Eviction Policy: Enforce RAM thresholds
        if (self.sessions.count() >= self.max_sessions) {
            try self.evictLRU();
        }

        const new_session = try self.allocator.create(ScriptSession);
        new_session.* = try ScriptSession.init(self.allocator, io);

        try self.sessions.put(self.allocator, session_id, new_session);
        try self.lru_queue.append(self.allocator, session_id);

        log.info("Initialized new session for {s} (ID: {x})", .{ canonical_path, session_id });
        return new_session;
    }

    fn markUsed(self: *SessionManager, session_id: u64) void {
        for (self.lru_queue.items, 0..) |id, i| {
            if (id == session_id) {
                _ = self.lru_queue.orderedRemove(i);
                self.lru_queue.append(self.allocator, session_id) catch {};
                return;
            }
        }
    }

    fn evictLRU(self: *SessionManager) !void {
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
