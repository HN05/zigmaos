// Sleeping locks
const std = @import("std");
const SpinLock = @import("spinlock.zig");
const execution = @import("execution.zig");

const SleepLock = @This();
// Long-term locks for processes

isLocked: bool = false, // Is the lock held?
spinlock: SpinLock = .{ .name = "sleep lock" }, // spinlock protecting this sleep lock
pid: ?usize = null,

// debug info
name: ?[]const u8 = null,

pub fn acquire(self: *SleepLock) void {
    self.spinlock.acquire();
    defer self.spinlock.release();

    while (self.isLocked) {
        self.spinlock.sleep(self);
    }

    self.isLocked = true;
    self.pid = execution.Process.getCurrentForce().pid_unsafe;
}

pub fn release(self: *SleepLock) void {
    self.spinlock.acquire();
    defer self.spinlock.release();

    self.isLocked = false;
    self.pid = null;

    execution.scheduler.wakeup(self);
}

pub fn isHolding(self: *SleepLock) bool {
    self.spinlock.acquire();
    defer self.spinlock.release();

    return self.isLocked and (self.pid == execution.Process.getCurrentForce().pid_unsafe);
}
