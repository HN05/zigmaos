// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig
const std = @import("std");
const Atomic = std.atomic.Value;
const interrupts = @import("interrupts.zig");
const Cpu = @import("cpu.zig");
const Process = @import("process.zig");
const scheduler = @import("scheduler.zig");

const SpinLock = @This();

isLocked: Atomic(bool) = .init(false),

name: ?[]const u8 = null,
cpu: ?*Cpu = null,

pub fn acquire(self: *SpinLock) void {
    interrupts.pushOff(); // disable interrupts to avoid deadlock.
    if (self.isHolding()) {
        @panic("acquire");
    }

    // spin trying to acquire
    while (self.isLocked.rmw(.Xchg, true, .acquire)) {}

    self.cpu = .getCurrent();
}

pub fn release(self: *SpinLock) void {
    if (!self.isHolding()) {
        @panic("release");
    }

    self.cpu = null;
    self.isLocked.store(false, .release);
    interrupts.popOff();
}

pub fn isHolding(self: *SpinLock) bool {
    return (self.isLocked.raw and self.cpu == .getCurrent());
}

// Atomically release lock and sleep on chan.
// Reacquires lock when awakened.
pub fn sleep(self: *SpinLock, channel: *anyopaque) void {
    scheduler.sleep(channel, self);
}
