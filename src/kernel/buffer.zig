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

const SpinLock = @import("spinlock.zig");
const SleepLock = @import("sleeplock.zig");
const common = @import("common");
const Device = @import("device.zig");
const virtio = @import("virtio.zig");
const fs = @import("filesystem.zig");
const std = @import("std");

const Buffer = @This();

is_valid: bool = false, // has data been read from disk?
disk_owned: bool = undefined, // does disk "own" buf?
device: Device.ID = undefined,
block_number: u32 = undefined,
lock: SleepLock = .{ .name = "buffer" },
reference_count: u32 = 0,
previous: *Buffer = undefined, // LRU cache list
next: *Buffer = undefined,
data: [fs.block_size]u8 align(8) = undefined,

pub fn castData(buffer: *Buffer, comptime T: type) *T {
    return std.mem.bytesAsValue(
        T,
        buffer.data[0..@sizeOf(T)],
    );
}

// cache
const Cache = struct {
    lock: SpinLock = .{ .name = "bcache" },
    buffer_array: [common.param.NBUF]Buffer = undefined, // undefined until calling init_array

    // Linked list of all buffers, through prev/next.
    // Sorted by how recently the buffer was used.
    // head.next is most recent, head.prev is least.
    head: Buffer = .{},

    pub fn init_array(self: *Cache) void {
        // Create linked list of buffers
        self.head.previous = &self.head;
        self.head.next = &self.head;

        for (&self.buffer_array) |*buffer| {
            buffer.* = .{};
            buffer.next = self.head.next;
            buffer.previous = &self.head;
            self.head.next.previous = buffer;
            self.head.next = buffer;
        }
    }

    // Look through buffer cache for block on device dev.
    // If not found, allocate a buffer.
    // In either case, return locked buffer.
    pub fn get_buffer(self: *Cache, device: Device.ID, block_number: u32) *Buffer {
        self.lock.acquire();
        var current_buffer = self.head.next;
        defer current_buffer.lock.acquire(); // acquire lock before returning
        defer self.lock.release(); // release before acquiring sleep lock

        // Is the block already cached?
        while (current_buffer != &self.head) : (current_buffer = current_buffer.next) {
            if (current_buffer.device == device and current_buffer.block_number == block_number) {
                current_buffer.reference_count += 1;
                return current_buffer;
            }
        }
        // Not cached.
        // Recycle the least recently used (LRU) unused buffer.
        current_buffer = self.head.previous;
        while (current_buffer != &self.head) : (current_buffer = current_buffer.previous) {
            if (current_buffer.reference_count == 0) {
                current_buffer.device = device;
                current_buffer.block_number = block_number;
                current_buffer.is_valid = false;
                current_buffer.reference_count = 1;
                return current_buffer;
            }
        }

        @panic("get_buffer: no buffers");
    }
};

pub const cache = &cacheBacking;
var cacheBacking = Cache{};

// Return a locked buf with the contents of the indicated block.
pub fn read(device: Device.ID, block_number: u32) *Buffer {
    const buffer = cache.get_buffer(device, block_number);
    if (!buffer.is_valid) {
        virtio.disk_driver.read(buffer);
        buffer.is_valid = true;
    }
    return buffer;
}

// Write buffer's contents to disk.  Must be locked.
pub fn write(buffer: *Buffer) void {
    if (!buffer.lock.isHolding()) @panic("buffer write");
    virtio.disk_driver.write(buffer);
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
    buffer.lock.acquire();
    defer buffer.lock.release();

    buffer.reference_count += 1;
}

pub fn unpin(buffer: *Buffer) void {
    buffer.lock.acquire();
    defer buffer.lock.release();

    buffer.reference_count -= 1;
}
