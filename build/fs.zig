const Device = @import("../src/kernel/filesystem/device.zig");

pub const ROOTINO = 1; // root i-number
pub const BSIZE = 1024; // block size

// Disk layout:
// [ boot block | super block | log | inode blocks | free bit map | data blocks ]
//
//
// Super block describes the disk layout:
pub const SuperBlock = extern struct {
    magic: u32, // Must be FSMAGIC
    size: u32, // Size of file system image (blocks)
    nblocks: u32, // Number of data blocks
    ninodes: u32, // Number of inodes.
    nlog: u32, // Number of log blocks
    logstart: u32, // Block number of first log block
    inodestart: u32, // Block number of first inode block
    bmapstart: u32, // Block number of first free map block

    const Self = @This();
    // Block containing inode i
    pub inline fn IBLOCK(self: *Self, i: u32) u32 {
        return i / IPB + self.inodestart;
    }

    // Block of free map containing bit for block b
    pub inline fn BBLOCK(self: *Self, b: u32) u32 {
        return b / BPB + self.bmapstart;
    }
};

pub const FSMAGIC = 0x10203040;

pub const NDIRECT = 12;
pub const NINDIRECT = (BSIZE / @sizeOf(u32));
pub const MAXFILE = (NDIRECT + NINDIRECT);

// On-disk inode structure
pub const Dinode = extern struct {
    device: Device.ID,
    size: u32, // Size of file (bytes)
    addrs: [NDIRECT + 1]u32, // Data block addresses
    type: u16, // File type
    nlink: u16, // Number of links to inode in file system
};

// Inodes per block.
pub const IPB = (BSIZE / @sizeOf(Dinode));

// Bitmap bits per block
pub const BPB = (BSIZE * 8);

pub const DIRENT_SIZE = 32;
pub const DIRSIZ = DIRENT_SIZE - @sizeOf(u32) - @sizeOf(u8); // 27

pub const Dirent = extern struct {
    inum: u32,
    name_length: u8,
    name: [DIRSIZ]u8,
};

