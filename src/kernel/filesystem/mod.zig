const log = @import("log.zig");
const exec_file = @import("exec.zig");
const buffer_cache = @import("buffer_cache.zig");
const blocks = @import("blocks.zig");

pub const Inode = @import("inode.zig");
pub const File = @import("file.zig");
pub const Directory = @import("directory.zig");
pub const Pipe = @import("pipe.zig");
pub const Buffer = @import("buffer.zig");
pub const Device = @import("device.zig");

pub const exec = exec_file.exec;
pub const initFileSystem = blocks.init;
pub const beginOperation = log.beginOperation;
pub const endOperation = log.endOperation;
pub const block_size = blocks.block_size;

pub fn initBufferCache() void {
    Buffer.cache.init_array();
}
