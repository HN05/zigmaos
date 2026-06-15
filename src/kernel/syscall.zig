const std = @import("std");
const log = @import("klog.zig");

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
    @cInclude("kernel/syscall.h");
    @cInclude("kernel/defs.h");
});

// Fetch the uint64 at addr from the current process.
export fn fetchaddr(address: c.uint64, ip: *c.uint64) c_int {
    const process = c.myproc();

    if (address >= process.*.sz or address + @sizeOf(c.uint64) > process.*.sz) {
        return -1;
    }

    const result = c.copyin(process.*.pagetable, @ptrCast(ip), address, @sizeOf(c.uint64));
    if (result != 0) {
        return -1;
    }
    return 0;
}

// Fetch the nul-terminated string at addr from the current process.
// Returns length of string, not including nul, or -1 for error.
export fn fetchstr(address: c.uint64, buffer: [*c]u8, max: c_int) c_int {
    const process = c.myproc();
    const result = c.copyinstr(process.*.pagetable, buffer, address, @intCast(max));
    if (result < 0) {
        return -1;
    }
    return c.strlen(buffer);
}

fn argraw(num: c_int) c.uint64 {
    const process = c.myproc();
    switch (num) {
        0 => return process.*.trapframe.*.a0,
        1 => return process.*.trapframe.*.a1,
        2 => return process.*.trapframe.*.a2,
        3 => return process.*.trapframe.*.a3,
        4 => return process.*.trapframe.*.a4,
        5 => return process.*.trapframe.*.a5,
        else => @panic("argraw"),
    }
}

// Fetch the nth 32-bit system call argument.
export fn argint(num: c_int, ip: *c_int) void {
    ip.* = @intCast(argraw(num));
}

// Retrieve an argument as a pointer.
// Doesn't check for legality, since
// copyin/copyout will do that.
export fn argaddr(num: c_int, ip: *c.uint64) void {
    ip.* = argraw(num);
}

// Fetch the nth word-sized system call argument as a null-terminated string.
// Copies into buf, at most max.
// Returns string length if OK (including nul), -1 if error.
export fn argstr(num: c_int, buffer: [*c]u8, max: c_int) c_int {
    var addr: c.uint64 = undefined;
    argaddr(num, &addr);
    return fetchstr(addr, buffer, max);
}

// Prototypes for the functions that handle system calls.
extern fn sys_fork() u64;
extern fn sys_exit() u64;
extern fn sys_wait() u64;
extern fn sys_pipe() u64;
extern fn sys_read() u64;
extern fn sys_kill() u64;
extern fn sys_exec() u64;
extern fn sys_fstat() u64;
extern fn sys_chdir() u64;
extern fn sys_dup() u64;
extern fn sys_getpid() u64;
extern fn sys_sbrk() u64;
extern fn sys_sleep() u64;
extern fn sys_uptime() u64;
extern fn sys_open() u64;
extern fn sys_write() u64;
extern fn sys_mknod() u64;
extern fn sys_unlink() u64;
extern fn sys_link() u64;
extern fn sys_mkdir() u64;
extern fn sys_close() u64;
extern fn sys_ringbuf() u64;

const SyscallFn = *const fn () callconv(.c) u64;

// An array mapping syscall numbers from syscall.h
// to the function that handles the system call.
const syscalls: [c.MAX_SYSCALL]?SyscallFn = blk: {
    var table: [c.MAX_SYSCALL]?SyscallFn = undefined;

    for (&table) |*entry| {
        entry.* = null;
    }

    table[c.SYS_fork] = sys_fork;
    table[c.SYS_exit] = sys_exit;
    table[c.SYS_wait] = sys_wait;
    table[c.SYS_pipe] = sys_pipe;
    table[c.SYS_read] = sys_read;
    table[c.SYS_kill] = sys_kill;
    table[c.SYS_exec] = sys_exec;
    table[c.SYS_fstat] = sys_fstat;
    table[c.SYS_chdir] = sys_chdir;
    table[c.SYS_dup] = sys_dup;
    table[c.SYS_getpid] = sys_getpid;
    table[c.SYS_sbrk] = sys_sbrk;
    table[c.SYS_sleep] = sys_sleep;
    table[c.SYS_uptime] = sys_uptime;
    table[c.SYS_open] = sys_open;
    table[c.SYS_write] = sys_write;
    table[c.SYS_mknod] = sys_mknod;
    table[c.SYS_unlink] = sys_unlink;
    table[c.SYS_link] = sys_link;
    table[c.SYS_mkdir] = sys_mkdir;
    table[c.SYS_close] = sys_close;
    table[c.SYS_ringbuf] = sys_ringbuf;

    break :blk table;
};

export fn syscall() void {
    const process = c.myproc();
    const num = process.*.trapframe.*.a7;

    if (num > 0 and num < syscalls.len) {
        if (syscalls[num]) |call| {
            process.*.trapframe.*.a0 = call();
        }
    } else {
        log.print("{d} {s}: unkown sys call {d}\n", .{ process.*.pid, process.*.name, num });
        process.*.trapframe.*.a0 = ~@as(c_ulong, 0);
    }
}
