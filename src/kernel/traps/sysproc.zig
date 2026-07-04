const kernel = @import("root");

const log = @import("../klog.zig");
const sysargs = @import("sysargs.zig");
const cpu_ticks = @import("../ticks.zig").cpu_ticks;

const Process = kernel.execution.Process;

pub fn sys_exit() u64 {
    const exitCode: u32 = @truncate(sysargs.getInt(.a0));
    Process.exit(@bitCast(exitCode));
    @panic("should not return after exit");
}

pub fn sys_getpid() u64 {
    return Process.getCurrentForce().pid_unsafe;
}

pub fn sys_fork() u64 {
    return Process.fork() catch sysargs.errorVal;
}

pub fn sys_wait() u64 {
    const address = sysargs.getAddress(.a0);
    return Process.wait(address) catch sysargs.errorVal;
}

pub fn sys_sbrk() u64 {
    const requestedBytes = sysargs.getInt(.a0);
    const oldSize = Process.getCurrentForce().size;

    Process.changeProcessSize(@bitCast(requestedBytes)) catch return sysargs.errorVal;
    return oldSize;
}

pub fn sys_sleep() u64 {
    const sleepTicks = sysargs.getInt(.a0);

    cpu_ticks.sleepFor(sleepTicks) catch {
        return sysargs.errorVal;
    };

    return 0;
}

pub fn sys_kill() u64 {
    const pid: u32 = @truncate(sysargs.getInt(.a0));
    Process.kill(@bitCast(pid)) catch return sysargs.errorVal;
    return 0;
}

pub fn sys_uptime() u64 {
    return cpu_ticks.readSafe();
}
