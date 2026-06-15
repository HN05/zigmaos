// Sleeping locks
const std = @import("std");
const CSpinlock = @import("spinlock.zig").CSpinlock;

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

// Long-term locks for processes
pub const Sleeplock = struct {
    isLocked: bool = false, // Is the lock held?
    spinlock: CSpinlock = .{}, // spinlock protecting this sleep lock
    pid: usize = 0,

    // debug info
    name: ?[]const u8 = null,
};

export fn initsleeplock(sleeplock: *c.struct_sleeplock, name: [*c]u8) void {
    CSpinlock.init(@ptrCast(&sleeplock.lk), "sleep lock");
    sleeplock.name = name;
    sleeplock.locked = 0;
    sleeplock.pid = 0;
}

export fn acquiresleep(sleeplock: *c.struct_sleeplock) void {
    CSpinlock.acquireLock(@ptrCast(&sleeplock.lk));
    defer CSpinlock.releaseLock(@ptrCast(&sleeplock.lk));

    while (sleeplock.locked != 0) {
        c.sleep(sleeplock, &sleeplock.lk);
    }
    sleeplock.locked = 1;
    sleeplock.pid = c.myproc().*.pid;
}

export fn releasesleep(sleeplock: *c.struct_sleeplock) void {
    CSpinlock.acquireLock(@ptrCast(&sleeplock.lk));
    defer CSpinlock.releaseLock(@ptrCast(&sleeplock.lk));

    sleeplock.locked = 0;
    sleeplock.pid = 0;
    c.wakeup(sleeplock);
}

export fn holdingsleep(sleeplock: *c.struct_sleeplock) c_int {
    CSpinlock.acquireLock(@ptrCast(&sleeplock.lk));
    defer CSpinlock.releaseLock(@ptrCast(&sleeplock.lk));

    const isLocked = sleeplock.locked != 0 and (sleeplock.pid == c.myproc().*.pid);
    return @intFromBool(isLocked);
}
