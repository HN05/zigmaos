const std = @import("std");
const log = @import("klog.zig");
const procsyscalls = @import("sysproc.zig");
const filesyscalls = @import("sysfile.zig");
const ringbuf = @import("ringbuf.zig");
const SyscallNum = @import("syscallnum.zig").SyscallNum;
const Process = @import("process.zig");

pub fn handler() void {
    const process = Process.getCurrentForce();
    const num = process.trapFrame.a7;

    const syscallNum: SyscallNum = @enumFromInt(num);

    //  TODO: make syscalls return void and throw error instead
    const result: u64 = switch (syscallNum) {
        .exit => procsyscalls.sys_exit(),
        .close => filesyscalls.sys_close(),
        .chdir => filesyscalls.sys_chdir(),
        .dup => filesyscalls.sys_dup(),
        .exec => filesyscalls.sys_exec(),
        .fork => procsyscalls.sys_fork(),
        .fstat => filesyscalls.sys_fstat(),
        .getpid => procsyscalls.sys_getpid(),
        .ringbuf => ringbuf.syscall(),
        .wait => procsyscalls.sys_wait(),
        .kill => procsyscalls.sys_kill(),
        .link => filesyscalls.sys_link(),
        .mkdir => filesyscalls.sys_mkdir(),
        .mknod => filesyscalls.sys_mknod(),
        .open => filesyscalls.sys_open(),
        .pipe => filesyscalls.sys_pipe(),
        .read => filesyscalls.sys_read(),
        .sbrk => procsyscalls.sys_sbrk(),
        .sleep => procsyscalls.sys_sleep(),
        .unlink => filesyscalls.sys_unlink(),
        .uptime => procsyscalls.sys_uptime(),
        .write => filesyscalls.sys_write(),
        else => ret: {
            log.print("{d} {s}: unkown sys call {d}\n", .{ process.pid_unsafe, process.nameSlice(), num });
            break :ret ~@as(usize, 0);
        },
    };

    process.trapFrame.a0 = result;
}
