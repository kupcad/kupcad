//! `InstructionHooks`: what the dispatch loop does before an instruction besides running
//! it, each off unless a host or a test turns it on: count it against a budget, check the
//! time against a deadline, collect garbage (to expose unrooted values), or stop at a new
//! line for the debugger. `active` says whether any is on, so the loop tests one flag;
//! checking each on every instruction cost a quarter of a tight loop's time.

const std = @import("std");

pub const InstructionHooks = struct {
    /// Most instructions a run may take; 0 for no limit.
    limit: usize = 0,
    /// When the run must stop, by the awake clock (VM.setTimeLimit); null for no limit.
    deadline: ?std.Io.Timestamp = null,
    /// The limit the deadline comes from, in milliseconds, for the message that stops a run.
    time_limit_ms: u64 = 0,
    /// Collect before every instruction (tests).
    zealous_gc: bool = false,
    /// Stop at each new line (the debugger's stepping).
    step: bool = false,
    /// Whether any of the above is on: set through the setters, which keep it.
    active: bool = false,

    pub fn setLimit(self: *InstructionHooks, limit: usize) void {
        self.limit = limit;
        self.refresh();
    }

    pub fn setDeadline(self: *InstructionHooks, deadline: ?std.Io.Timestamp, time_limit_ms: u64) void {
        self.deadline = deadline;
        self.time_limit_ms = time_limit_ms;
        self.refresh();
    }

    pub fn setZealousGc(self: *InstructionHooks, on: bool) void {
        self.zealous_gc = on;
        self.refresh();
    }

    pub fn setStep(self: *InstructionHooks, on: bool) void {
        self.step = on;
        self.refresh();
    }

    fn refresh(self: *InstructionHooks) void {
        self.active = self.limit > 0 or self.deadline != null or self.zealous_gc or self.step;
    }
};
