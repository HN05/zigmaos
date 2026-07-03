const std = @import("std");

const ad = @import("../address.zig");

pub const max_device_count = 10;
pub const console_major = 1;
pub const disk_major = 2;

pub const ID = packed struct(u32) {
    const total_bits = @bitSizeOf(u32);
    pub const minor_bit_size = total_bits - major_bit_size;
    pub const major_bit_size = std.math.log2_int_ceil(usize, max_device_count);

    major: std.meta.Int(.unsigned, major_bit_size),
    minor: std.meta.Int(.unsigned, minor_bit_size),

    pub const root_fs_device = @This(){ .major = disk_major, .minor = 1 };
    pub const zero = @This(){ .major = 0, .minor = 0 };
};

const Device = @This();

// map major device number to device functions.
// addr kind, address, number
read: ?*const fn (ad.AnyAddress, u32) ReadErrors!u32 = null,
write: ?*const fn (ad.AnyAddress, u32) WriteErrors!u32 = null,

pub var deviceTable = [_]Device{.{}} ** max_device_count;

pub const ReadErrors = error{ ProcessKilled, NoRunningProcess };
pub const WriteErrors = error{};
