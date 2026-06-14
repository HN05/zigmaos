const std = @import("std");

pub fn FlagOps(comptime Flag: type) type {
    return struct {
        pub inline fn mask(flag: Flag) usize {
            return @intFromEnum(flag);
        }

        pub inline fn set(flag: Flag, value: usize) usize {
            return value | mask(flag);
        }

        pub inline fn clear(flag: Flag, value: usize) usize {
            return value & ~mask(flag);
        }

        pub inline fn isSet(flag: Flag, value: usize) bool {
            return (value & mask(flag)) != 0;
        }
    };
}

pub fn RegisterWithFlags(comptime name: []const u8, comptime Flag: type) type {
    return struct {
        pub const registerName = name;
        pub const flags = FlagOps(Flag);

        pub inline fn read() usize {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> usize),
            );
        }

        pub inline fn write(value: usize) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }

        pub inline fn set(bit: Flag) void {
            write(flags.set(bit, read()));
        }

        pub inline fn clear(bit: Flag) void {
            write(flags.clear(bit, read()));
        }

        pub inline fn isSet(bit: Flag) bool {
            return flags.isSet(bit, read());
        }
    };
}

pub fn Register(comptime name: []const u8) type {
    return struct { 
        pub const registerName = name;
        pub inline fn read() usize {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> usize),
            );
        }

        pub inline fn write(value: usize) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }

    };
}