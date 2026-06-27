const Inode = @import("inode.zig");
const Pipe = @import("pipe.zig");

pub const Kind = enum {
none, pipe, inode, device,
};

const File = @This();

kind: Kind,
reference_count: u32,
readable: bool,
writeable: bool,
pipe: *Pipe,// FD_PIPE
inode: *Inode,// FD_INODE and FD_DEVICE
offset: u32,// FD_INODE
major: u16,// FD_DEVICE

