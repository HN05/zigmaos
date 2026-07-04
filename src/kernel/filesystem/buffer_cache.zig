const kernel = @import("root");
const common = @import("common");

const Buffer = @import("buffer.zig");
const DiskBlock = @import("diskblock.zig");
const Device = @import("device.zig");

const Mutex = kernel.concurrency.Mutex;

const Cache = @This();

lock: Mutex = .init(.spin, "bcache"),
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
pub fn get_buffer(self: *Cache, block: DiskBlock) *Buffer {
    self.lock.acquire();
    var current_buffer = self.head.next;
    defer current_buffer.lock.acquire(); // acquire lock before returning
    defer self.lock.release(); // release before acquiring sleep lock

    // Is the block already cached?
    while (current_buffer != &self.head) : (current_buffer = current_buffer.next) {
        if (current_buffer.block.eql(block)) {
            current_buffer.reference_count += 1;
            return current_buffer;
        }
    }
    // Not cached.
    // Recycle the least recently used (LRU) unused buffer.
    current_buffer = self.head.previous;
    while (current_buffer != &self.head) : (current_buffer = current_buffer.previous) {
        if (current_buffer.reference_count == 0) {
            current_buffer.block = block;
            current_buffer.is_valid = false;
            current_buffer.reference_count = 1;
            return current_buffer;
        }
    }

    @panic("get_buffer: no buffers");
}
