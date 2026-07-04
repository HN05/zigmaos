const log = @import("log.zig");
const exec_file = @import("exec.zig");
const buffer_cache = @import("buffer_cache.zig");
const DiskBlock = @import("diskblock.zig");

const super_block = @import("superblock.zig");
pub const Inode = @import("inode.zig");
pub const File = @import("file.zig");
pub const Directory = @import("directory.zig");
pub const Pipe = @import("pipe.zig");
pub const Buffer = @import("buffer.zig");
pub const Device = @import("device.zig");

pub const SuperBlock = super_block.SuperBlock;
pub const exec = exec_file.exec;
pub const beginOperation = log.beginOperation;
pub const endOperation = log.endOperation;
pub const block_size = DiskBlock.block_size;

pub fn initBufferCache() void {
    Buffer.cache.init_array();
}

pub fn initFileSystem(device: Device.ID) void {
    super_block.initGlobal(device);
    log.init(device, super_block.global);
}

