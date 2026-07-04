const kernel = @import("root");

const execution = kernel.execution;
const Mutex = kernel.concurrency.Mutex;

const Ticks = @This();

pub const cpu_ticks = &ticksBacking;
var ticksBacking: Ticks = .{};

ticks_unsafe: usize = 0,
lock: Mutex = .init(.spin, "ticks lock"),

pub fn incrementSafe(self: *Ticks) void {
    {
        self.lock.acquire();
        defer self.lock.release();

        self.ticks_unsafe += 1;
    }
    execution.scheduler.wakeup(self);
}

pub fn readSafe(self: *Ticks) usize {
    self.lock.acquire();
    defer self.lock.release();

    return self.ticks_unsafe;
}

pub fn sleepFor(self: *Ticks, ticksToSleep: usize) !void {
    self.lock.acquire();
    defer self.lock.release();

    const ticks0 = self.ticks_unsafe;
    while (self.ticks_unsafe - ticks0 < ticksToSleep) {
        if (execution.Process.isKilled(.getCurrentForce())) {
            return error.ProcessIsKilled;
        }
        self.lock.sleepOn(self);
    }
}
