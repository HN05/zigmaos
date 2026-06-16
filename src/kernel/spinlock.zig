// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig
const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
});
const std = @import("std");
const Atomic = std.atomic.Value;
const riscv = @import("common").riscv;
const csr = @import("csr.zig");

pub const SpinLock = struct {
    isLocked: Atomic(bool) = .init(false),

    name: ?[]const u8 = null,
    cpu: ?*c.struct_cpu = null,

    pub fn acquire(self: *SpinLock) void {
        push_off(); // disable interrupts to avoid deadlock.
        if (self.isHolding()) {
            @panic("acquire");
        }

        // spin trying to acquire
        while (self.isLocked.rmw(.Xchg, true, .acquire)) {}

        self.cpu = c.mycpu();
    }

    pub fn release(self: *SpinLock) void {
        if (!self.isHolding()) {
            @panic("release");
        }

        self.cpu = null;
        self.isLocked.store(false, .release);
        pop_off();
    }

    pub fn isHolding(self: *SpinLock) bool {
        return (self.isLocked.raw and self.cpu == c.mycpu());
    }

    // Atomically release lock and sleep on chan.
    // Reacquires lock when awakened.
    pub fn sleep(self: *SpinLock, channel: *anyopaque) void {
        const process = c.myproc();

        // Must acquire p->lock in order to
        // change p->state and then call sched.
        // Once we hold p->lock, we can be
        // guaranteed that we won't miss any wakeup
        // (wakeup locks p->lock),
        // so it's okay to release lk.
        c.acquire(&process.*.lock);
        self.release();

        // Go to sleep.
        process.*.chan = channel;
        process.*.state = c.SLEEPING;

        c.sched();

        // Tidy up.
        process.*.chan = null;
        c.release(&process.*.lock);
        self.acquire();
    }
};

// push_off/pop_off are like intr_off()/intr_on() except that they are matched:
// it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
// are initially off, then push_off, pop_off leaves them off.
export fn push_off() void {
    const interruptsOn = csr.interrupts_is_on();
    csr.interrupts_off();

    const cpu = c.mycpu();
    if (cpu.*.noff == 0) {
        cpu.*.intena = @intFromBool(interruptsOn);
    }
    cpu.*.noff += 1;
}

export fn pop_off() void {
    if (csr.interrupts_is_on()) {
        @panic("pop_off - interruptible");
    }

    const cpu = c.mycpu();
    if (cpu.*.noff < 1) {
        @panic("pop_off");
    }

    cpu.*.noff -= 1;
    if (cpu.*.noff == 0 and cpu.*.intena != 0) {
        csr.interrupts_on();
    }
}

//  TODO: remove under

const c_spinlock = extern struct {
    locked: u32 = 0, // Is the lock held?
    name: ?[*:0]const u8 = null,
    cpu: ?*c.struct_cpu = null,
};

pub const CSpinlock = extern struct {
    const Self = @This();
    lock: c_spinlock,

    pub fn init(self: *Self, name: ?[*:0]const u8) void {
        initlock(@ptrCast(&self.lock), @ptrCast(@constCast(name)));
    }
    pub fn acquireLock(self: *CSpinlock) void {
        acquire(@ptrCast(&self.lock));
    }
    pub fn releaseLock(self: *CSpinlock) void {
        release(@ptrCast(&self.lock));
    }
    pub fn isHoldingLock(self: *CSpinlock) bool {
        return holding(@ptrCast(&self.lock)) == 1;
    }
};

export fn initlock(spinlock: *c.struct_spinlock, name: [*c]u8) void {
    spinlock.name = name;
    spinlock.locked = 0;
    spinlock.cpu = 0;
}

// Acquire the lock.
// Loops (spins) until the lock is acquired.
export fn acquire(spinlock: *c.struct_spinlock) void {
    push_off(); // disable interrupts to avoid deadlock.
    if (isHolding(spinlock)) {
        @panic("acquire");
    }

    // spin trying to acquire
    while (@atomicRmw(u32, &spinlock.locked, .Xchg, 1, .acquire) != 0) {}

    spinlock.cpu = c.mycpu();
}

export fn release(spinlock: *c.struct_spinlock) void {
    if (!isHolding(spinlock)) {
        @panic("release");
    }

    spinlock.cpu = 0;

    @atomicStore(u32, &spinlock.locked, 0, .release);

    pop_off();
}

// Check whether this cpu is holding the lock.
// Interrupts must be off.
fn isHolding(spinlock: *c.struct_spinlock) bool {
    return (spinlock.locked != 0 and spinlock.cpu == c.mycpu());
}

export fn holding(spinlock: *c.struct_spinlock) c_int {
    return @intFromBool(isHolding(spinlock));
}

