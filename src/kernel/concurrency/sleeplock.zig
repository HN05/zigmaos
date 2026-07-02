const kernel = @import("root");
const std = @import("std");

const SpinLock = @import("spinlock.zig");
const Mutex = @import("mutex.zig").Mutex;

const scheduler = kernel.execution.scheduler;
const Process = kernel.execution.Process;

const SleepLock = @This();
// Long-term locks for processes

isLocked: bool = false, // Is the lock held?
lock: SpinLock = .{ .name = "sleep lock" }, // lock protecting this sleep lock
pid: ?usize = null,
name: []const u8, // for debug

pub fn acquire(self: *SleepLock) void {
    self.lock.acquire();
    defer self.lock.release();

    var mutex = Mutex{ .reference = .{ .spin = &self.lock } };

    // sleep while lock is held
    while (self.isLocked) {
        scheduler.sleepWithLock(&mutex, self);
    }

    // get the lock
    self.isLocked = true;
    self.pid = Process.getCurrentForce().pid_unsafe;
}

pub fn release(self: *SleepLock) void {
    self.lock.acquire();
    defer self.lock.release();

    self.isLocked = false;
    self.pid = null;

    // wakeup others wanting to acquire lock
    scheduler.wakeup(self);
}

pub fn isHolding(self: *SleepLock) bool {
    self.lock.acquire();
    defer self.lock.release();

    return self.isLocked and (self.pid == Process.getCurrentForce().pid_unsafe);
}
