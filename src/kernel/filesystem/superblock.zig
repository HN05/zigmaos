const std = @import("std");

const DiskBlock = @import("diskblock.zig");
const Inode = @import("inode.zig");
const Device = @import("device.zig");
const Buffer = @import("buffer.zig");
const log = @import("log.zig");

// Disk layout:
// [ boot block | super block | log | inode blocks |
//                                          free bit map | data blocks]
//
// mkfs computes the super block and builds an initial file system. The
// super block describes the disk layout:
pub const SuperBlock = extern struct {
    magic: u32, // Must be FSMAGIC
    size: u32, // Size of file system image (blocks)
    nblocks: u32, // Number of data blocks
    ninodes: u32, // Number of inodes.
    nlog: u32, // Number of log blocks
    logstart: u32, // Block number of first log block
    inodestart: u32, // Block number of first inode block
    bmapstart: u32, // Block number of first free map block

    pub const correct_magic = 0x10203040;
    pub fn hasCorrectMagic(self: *SuperBlock) bool {
        return self.magic == correct_magic;
    }

    // Block of free map containing bit for block b
    pub fn getFreeMapBlockNumber(self: *SuperBlock, block_number: DiskBlock.BlockNumber) DiskBlock.BlockNumber {
        return block_number / DiskBlock.bitmap_bits_per_block + self.bmapstart;
    }

    // Block containing inode i
    pub fn getInodeBlockNumber(self: *SuperBlock, inode_number: Inode.InodeNumber) DiskBlock.BlockNumber {
        return inode_number / Inode.inodes_per_block + self.inodestart;
    }
};

// File system implementation.  Five layers:
//   + Blocks: allocator for raw disk blocks.
//   + Log: crash recovery for multi-step updates.
//   + Files: inode allocator, reading, writing, metadata.
//   + Directories: inode with special contents (list of other inodes!)
//   + Names: paths like /usr/rtm/xv6/fs.c for convenient naming.
//
// This file contains the low-level file system manipulation
// routines.  The (higher-level) system call implementations
// are in sysfile.c.

// there should be one superblock per disk device, but we run with
// only one device
pub const global = &global_backing;
var global_backing: SuperBlock = undefined;

// Read the super block.
pub fn initGlobal(device: Device.ID) void {
    const buffer = Buffer.read(.init(1, device));
    defer buffer.release();

    @memmove(
        std.mem.asBytes(global),
        buffer.data[0..@sizeOf(SuperBlock)],
    );
    if (!global.hasCorrectMagic()) @panic("invalid file system");
}
