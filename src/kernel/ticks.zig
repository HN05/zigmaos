const SpinLock = @import("spinlock.zig");
const execution = @import("execution.zig");

pub const ticks = &ticksBacking;

var ticksBacking: Ticks = .{};

const Ticks = struct {
    ticks: usize = 0,
    lock: SpinLock =.{ .name = "ticks lock" }, 

    const SleepError = error {
    Killed,
};
    pub fn incrementSafe(self: *Ticks) void {
        {
            self.lock.acquire();
            defer self.lock.release();

            self.ticks += 1;
        }
        execution.scheduler.wakeup(self);
    }

    pub fn readSafe(self: *Ticks) usize {
        self.lock.acquire();
        defer self.lock.release();

        return self.ticks;
    }

    pub fn sleepFor(self: *Ticks, ticksToSleep: usize) SleepError!void {
        self.lock.acquire();
        defer self.lock.release();

        const ticks0 = self.ticks;
        while (self.ticks - ticks0 < ticksToSleep) {
            if (execution.Process.isKilled(.getCurrentForce())) {
                return SleepError.Killed;
            }
            self.lock.sleep(self);
        }
    }
};

