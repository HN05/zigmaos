const std = @import("std");

const Device = @import("device.zig");
const Buffer = @import("buffer.zig");
const log = @import("log.zig");
const Inode = @import("inode.zig");

pub const block_size = 1024;
const bitmap_bits_per_block = block_size * 8;

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
    pub fn getFreeMapBlock(self: *SuperBlock, block: u32) u32 {
        return block / bitmap_bits_per_block + self.bmapstart;
    }

    // Block containing inode i
    pub fn getInodeBlock(self: *SuperBlock, inode_number: u32) u32 {
        return inode_number / Inode.inodes_per_block + self.inodestart;
    }
};

const BlockBitmap = struct {
    bytes: []u8,

    pub fn isUsed(self: BlockBitmap, bit_index: usize) bool {
        const byte_index = bit_index / 8;
        const bit_offset: u3 = @intCast(bit_index % 8);
        const mask: u8 = @as(u8, 1) << bit_offset;

        return (self.bytes[byte_index] & mask) != 0;
    }

    pub fn markUsed(self: BlockBitmap, bit_index: usize) void {
        const byte_index = bit_index / 8;
        const bit_offset: u3 = @intCast(bit_index % 8);
        const mask: u8 = @as(u8, 1) << bit_offset;

        self.bytes[byte_index] |= mask;
    }

    pub fn markFree(self: BlockBitmap, bit_index: usize) void {
        if (!self.isUsed(bit_index)) @panic("trying to free unused block");
        const byte_index = bit_index / 8;
        const bit_offset: u3 = @intCast(bit_index % 8);
        const mask: u8 = @as(u8, 1) << bit_offset;

        self.bytes[byte_index] &= ~mask;
    }

    pub fn findFree(self: BlockBitmap, max_bits: u32) ?usize {
        var bit_index: usize = 0;
        while (bit_index < max_bits) : (bit_index += 1) {
            if (!self.isUsed(bit_index)) return bit_index;
        }
        return null;
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
pub var superBlock: SuperBlock = undefined;

// Read the super block.
fn readSuperBlock(device: Device.ID, superBlockDestination: *SuperBlock) void {
    const buffer = Buffer.read(device, 1);
    defer buffer.release();

    @memmove(
        std.mem.asBytes(superBlockDestination),
        buffer.data[0..@sizeOf(SuperBlock)],
    );
}

// Init fs
pub fn init(device: Device.ID) void {
    readSuperBlock(device, &superBlock);
    if (!superBlock.hasCorrectMagic()) @panic("invalid file system");
    log.init(device, superBlock);
}

// Zero a block.
fn zeroBlock(device: Device.ID, block_number: u32) void {
    const buffer = Buffer.read(device, block_number);
    defer buffer.release();

    @memset(&buffer.data, 0);
    log.write(buffer);
}

// Allocate a zeroed disk block.
pub fn blockAllocate(device: Device.ID) !u32 {
    var block_number: u32 = 0;
    while (block_number < superBlock.size) : (block_number += bitmap_bits_per_block) {
        var allocated_block: ?u32 = null;
        {
            const buffer = Buffer.read(device, superBlock.getFreeMapBlock(block_number));
            defer buffer.release();

            const bitmap = BlockBitmap{
                .bytes = buffer.data[0..],
            };

            const remaining_blocks = superBlock.size - block_number;
            const max_blocks = @min(bitmap_bits_per_block, remaining_blocks);

            if (bitmap.findFree(max_blocks)) |block_index| {
                bitmap.markUsed(block_index);
                log.write(buffer);

                allocated_block = @intCast(block_number + block_index);
            }
        }
        if (allocated_block) |block| {
            zeroBlock(device, block);
            return block;
        }
    }
    return error.OutOfBlocks;
}

// Free a disk block.
pub fn blockFree(device: Device.ID, block_number: u32) void {
    const buffer = Buffer.read(device, superBlock.getFreeMapBlock(block_number));
    defer buffer.release();

    const bitmap = BlockBitmap{
        .bytes = buffer.data[0..],
    };

    const block_offset = block_number % bitmap_bits_per_block;

    bitmap.markFree(block_offset);
    log.write(buffer);
}
