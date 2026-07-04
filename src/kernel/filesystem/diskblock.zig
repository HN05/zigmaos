const Device = @import("device.zig");
const Buffer = @import("buffer.zig");
const super_block = @import("superblock.zig").global;
const log = @import("log.zig");

pub const block_size = 1024;
pub const bitmap_bits_per_block = block_size * 8;

const DiskBlock = @This();
pub const BlockNumber = u32;

number: BlockNumber,
device: Device.ID,

// Zero a block.
fn zero(block: DiskBlock) void {
    const buffer = block.read();
    defer buffer.release();

    @memset(&buffer.data, 0);
    log.write(buffer);
}

pub fn init(block_number: BlockNumber, device: Device.ID) DiskBlock {
    return .{ .number = block_number, .device = device };
}

pub fn eql(self: DiskBlock, other: DiskBlock) bool {
    return self.device == other.device and self.number == other.number;
}

pub fn read(self: DiskBlock) *Buffer {
    return Buffer.read(self);
}

// Allocate a zeroed disk block.
pub fn allocate(device: Device.ID) !DiskBlock {
    var block_number: BlockNumber = 0;
    while (block_number < super_block.size) : (block_number += bitmap_bits_per_block) {
        var allocated_block: ?DiskBlock = null;
        {
            const free_block_number = super_block.getFreeMapBlockNumber(block_number);
            const buffer = Buffer.read(.init(free_block_number, device));
            defer buffer.release();

            const bitmap = BlockBitmap{
                .bytes = buffer.data[0..],
            };

            const remaining_blocks = super_block.size - block_number;
            const max_blocks = @min(bitmap_bits_per_block, remaining_blocks);

            if (bitmap.findFree(max_blocks)) |block_index| {
                bitmap.markUsed(block_index);
                log.write(buffer);

                allocated_block = .init(@intCast(block_number + block_index), device);
            }
        }
        if (allocated_block) |block| {
            block.zero();
            return block;
        }
    }
    return error.OutOfBlocks;
}

// Free a disk block.
pub fn free(block: DiskBlock) void {
    const block_number = super_block.getFreeMapBlockNumber(block.number);
    const buffer = Buffer.read(.init(block_number, block.device));
    defer buffer.release();

    const bitmap = BlockBitmap{
        .bytes = buffer.data[0..],
    };

    const block_offset = block.number % bitmap_bits_per_block;

    bitmap.markFree(block_offset);
    log.write(buffer);
}

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
