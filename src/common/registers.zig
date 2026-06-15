const std = @import("std");

pub const UserRegister = enum(u5) {
    zero = 0, // x0, hardwired zero
    ra = 1, // x1
    sp = 2, // x2
    gp = 3, // x3
    tp = 4, // x4

    t0 = 5, // x5
    t1 = 6, // x6
    t2 = 7, // x7

    s0 = 8, // x8 / fp
    s1 = 9, // x9

    a0 = 10, // x10, syscall return value / arg0
    a1 = 11, // x11
    a2 = 12, // x12
    a3 = 13, // x13
    a4 = 14, // x14
    a5 = 15, // x15
    a6 = 16, // x16
    a7 = 17, // x17, syscall number

    s2 = 18, // x18
    s3 = 19, // x19
    s4 = 20, // x20
    s5 = 21, // x21
    s6 = 22, // x22
    s7 = 23, // x23
    s8 = 24, // x24
    s9 = 25, // x25
    s10 = 26, // x26
    s11 = 27, // x27

    t3 = 28, // x28
    t4 = 29, // x29
    t5 = 30, // x30
    t6 = 31, // x31

    pub inline fn write(register: UserRegister, value: usize) void {
        if (register == .zero) {
            return;
        }
        asm volatile (std.fmt.comptimePrint("mv x{d}, a0", .{@intFromEnum(register)})
            :
            : [value] "{a0}" (value),
        );
    }

    pub inline fn read(register: UserRegister) usize {
        if (register == .zero) {
            return 0;
        }
        return asm volatile (std.fmt.comptimePrint("mv a0, x{d}", .{@intFromEnum(register)})
            : [ret] "={a0}" (-> usize),
        );
    }
};
