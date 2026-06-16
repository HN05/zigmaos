const std = @import("std");
const log = @import("klog.zig");
const procsyscalls = @import("sysproc.zig");
const ringbuf = @import("ringbuf.zig");
const SyscallNum = @import("syscallnum.zig").SyscallNum;

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
    @cInclude("kernel/defs.h");
});

// Prototypes for the functions that handle system calls.
extern fn sys_fstat() u64;
extern fn sys_chdir() u64;
extern fn sys_dup() u64;
extern fn sys_read() u64;
extern fn sys_open() u64;
extern fn sys_write() u64;
extern fn sys_mknod() u64;
extern fn sys_unlink() u64;
extern fn sys_link() u64;
extern fn sys_mkdir() u64;
extern fn sys_close() u64;
extern fn sys_pipe() u64;
extern fn sys_exec() u64;

export fn syscall() void {
    const process = c.myproc();
    const num = process.*.trapframe.*.a7;

    const syscallNum: SyscallNum = @enumFromInt(num);

    const result: u64 = switch (syscallNum) {
        .exit => procsyscalls.sys_exit(),
        .close => sys_close(),
        .chdir => sys_chdir(),
        .dup => sys_dup(),
        .exec => sys_exec(),
        .fork => procsyscalls.sys_fork(),
        .fstat => sys_fstat(),
        .getpid => procsyscalls.sys_getpid(),
        .ringbuf => ringbuf.syscall(),
        .wait => procsyscalls.sys_wait(),
        .kill => procsyscalls.sys_kill(),
        .link => sys_link(),
        .mkdir => sys_mkdir(),
        .mknod => sys_mknod(),
        .open => sys_open(),
        .pipe => sys_pipe(),
        .read => sys_read(),
        .sbrk => procsyscalls.sys_sbrk(),
        .sleep => procsyscalls.sys_sleep(),
        .unlink => sys_unlink(),
        .uptime => procsyscalls.sys_uptime(),
        .write => sys_write(),
        else => ret: {
            log.print("{d} {s}: unkown sys call {d}\n", .{ process.*.pid, process.*.name, num });
            break :ret ~@as(usize, 0);
        },
    };

    process.*.trapframe.*.a0 = @intCast(result);
}
