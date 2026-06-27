const SleepLock = @import("sleeplock.zig");
const device = @import("device.zig");

const Inode = @This();

pub const Kind = enum {
    directory,
    device,
    file,
};

const ndirect = 12;

// in-memory copy of an inode
device_number: u32,
inode_number: u32,
reference_count: u32,
lock: SleepLock,// protects everything below here
isValid: bool,// inode has been read from disk?

type: u16, // copy of disk inode
device_id: device.ID,
link_number: u16,
size: u32,
addresses: [ndirect + 1]u32,


