// Buffer cache.
//
// The buffer cache is a linked list of buf structures holding
// cached copies of disk block contents.  Caching disk blocks
// in memory reduces the number of disk reads and also provides
// a synchronization point for disk blocks used by multiple processes.
//
// Interface:
// * To get a buffer for a particular disk block, call bread.
// * After changing buffer data, call bwrite to write it to disk.
// * When done with the buffer, call brelse.
// * Do not use the buffer after calling brelse.
// * Only one process at a time can use a buffer,
//     so do not keep them longer than necessary.
const kernel = @import("root");
const std = @import("std");

const Device = @import("device.zig");
const Cache = @import("buffer_cache.zig");
const DiskBlock = @import("diskblock.zig");

const Mutex = kernel.concurrency.Mutex;
const drivers = kernel.drivers;

const Buffer = @This();

is_valid: bool = false, // has data been read from disk?
disk_owned: bool = false, // does disk "own" buf?
block: DiskBlock = .{},
lock: Mutex = .init(.sleep, "buffer"),
reference_count: u32 = 0,
previous: *Buffer = undefined, // LRU cache list
next: *Buffer = undefined,
data: [DiskBlock.block_size]u8 align(8) = undefined,

pub fn castData(buffer: *Buffer, comptime T: type) *T {
    return std.mem.bytesAsValue(
        T,
        buffer.data[0..@sizeOf(T)],
    );
}

pub const cache = &cacheBacking;
var cacheBacking = Cache{};

// Return a locked buf with the contents of the indicated block.
pub fn read(block: DiskBlock) *Buffer {
    const buffer = cache.get_buffer(block);
    if (!buffer.is_valid) {
        drivers.disk.read(buffer);
        buffer.is_valid = true;
    }
    return buffer;
}

// Write buffer's contents to disk.  Must be locked.
pub fn write(buffer: *Buffer) void {
    if (!buffer.lock.isHolding()) @panic("buffer write");
    drivers.disk.write(buffer);
}

// Release a locked buffer.
// Move to the head of the most-recently-used list.
pub fn release(buffer: *Buffer) void {
    if (!buffer.lock.isHolding()) @panic("buffer release");

    buffer.lock.release();

    cache.lock.acquire();
    defer cache.lock.release();

    buffer.reference_count -= 1;

    if (buffer.reference_count == 0) {
        // no one is waiting for it.
        buffer.next.previous = buffer.previous;
        buffer.previous.next = buffer.next;

        buffer.next = cache.head.next;
        buffer.previous = &cache.head;

        cache.head.next.previous = buffer;
        cache.head.next = buffer;
    }
}

pub fn pin(buffer: *Buffer) void {
    cache.lock.acquire();
    defer cache.lock.release();

    buffer.reference_count += 1;
}

pub fn unpin(buffer: *Buffer) void {
    cache.lock.acquire();
    defer cache.lock.release();

    buffer.reference_count -= 1;
}
