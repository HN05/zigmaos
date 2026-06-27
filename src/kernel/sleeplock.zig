// Sleeping locks
const std = @import("std");
const SpinLock = @import("spinlock.zig");
const Process = @import("process.zig");
const scheduler = @import("scheduler.zig");

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
    self.pid = Process.getCurrentForce().pid_unsafe;
}

pub fn release(self: *SleepLock) void {
    self.spinlock.acquire();
    defer self.spinlock.release();

    self.isLocked = false;
    self.pid = null;

    scheduler.wakeup(self);
}

pub fn isHolding(self: *SleepLock) bool {
    self.spinlock.acquire();
    defer self.spinlock.release();

    return self.isLocked and (self.pid == Process.getCurrentForce().pid_unsafe);
}
