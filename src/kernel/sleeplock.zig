// Sleeping locks
const std = @import("std");
const spinlocks = @import("spinlock.zig");
const CSpinlock = spinlocks.CSpinlock;
const SpinLock = spinlocks.SpinLock;

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/sleeplock.h");
    @cInclude("kernel/fs.h"); // required before file.h
    @cInclude("kernel/file.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/proc.h");
});

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
    self.pid = c.myproc().*.pid;
}

pub fn release(self: *SleepLock) void {
    self.spinlock.acquire();
    defer self.spinlock.release();

    self.isLocked = false;
    self.pid = null;

    c.wakeup(self);
}

pub fn isHolding(self: *SleepLock) bool {
    self.spinlock.acquire();
    defer self.spinlock.release();

    return self.isLocked and (self.pid == c.myproc().*.pid);
}
