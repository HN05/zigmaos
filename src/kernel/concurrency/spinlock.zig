const kernel = @import("root");
const std = @import("std");

const interrupts = @import("interrupts.zig");

const Atomic = std.atomic.Value;
const Cpu = kernel.execution.Cpu;

const SpinLock = @This();

isLocked: Atomic(bool) = .init(false),
cpu: ?*Cpu = null,

name: []const u8,

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

pub fn isHolding(self: *const SpinLock) bool {
    return (self.isLocked.raw and self.cpu == Cpu.getCurrent());
}
