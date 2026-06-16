const std = @import("std");
const log = @import("klog.zig");

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
    @cInclude("kernel/defs.h");
});

const InputRegister = enum { a0, a1, a2, a3, a4, a5 };
pub const errorVal = ~@as(u64, 0);

pub fn int(register: InputRegister) usize {
    const process = c.myproc();
    const result = switch (register) {
        .a0 => process.*.trapframe.*.a0,
        .a1 => process.*.trapframe.*.a1,
        .a2 => process.*.trapframe.*.a2,
        .a3 => process.*.trapframe.*.a3,
        .a4 => process.*.trapframe.*.a4,
        .a5 => process.*.trapframe.*.a5,
    };
    return @intCast(result);
}


// Retrieve an argument as a pointer.
// Doesn't check for legality, since
// copyin/copyout will do that.
pub fn addr(register: InputRegister) *anyopaque {
    return @ptrFromInt(int(register));
}


// Fetch the nth word-sized system call argument as a null-terminated string.
// Copies into buf, at most max.
// Returns string length if OK (including nul), -1 if error.
pub fn str(register: InputRegister, buffer: []u8, max: usize) !usize {
    return c.fetchstr(addr(register), buffer, max);
}


// c helpers to remove
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
    var address: c.uint64 = undefined;
    argaddr(num, &address);
    return c.fetchstr(address, buffer, max);
}

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

