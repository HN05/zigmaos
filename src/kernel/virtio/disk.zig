const SpinLock = @import("../spinlock.zig");
const Buffer = @import("../buffer.zig");

// this many virtio descriptors.
// must be a power of two.
pub const queue_size = 8;
pub const DiskQueue = @import("queue.zig").Queue(queue_size);

// a set (not a ring) of DMA descriptors, with which the
// driver tells the device where to read and write individual
// disk operations. there are NUM descriptors.
// most commands consist of a "chain" (a linked list) of a couple of
// these descriptors.
descriptor: [queue_size]DiskQueue.Descriptor,

// a ring in which the driver writes descriptor numbers
// that the driver would like the device to process
// includes the head descriptor of each chain. the ring has
// NUM elements.
available: *DiskQueue.Available,

// a ring in which the device writes descriptor numbers that
// the device has finished processing (just the head of each chain).
// there are NUM used ring entries.
used: *DiskQueue.Used,

// our own book-keeping.
free: [queue_size]bool, // is a descriptor free?
used_idx: u16, // we've looked this far in used[2..NUM].

// track info about in-flight operations,
// for use when completion interrupt arrives.
// indexed by first descriptor index of chain.
info: [queue_size]StatusBuffer,

// disk command headers.
// one-for-one with descriptors, for convenience.
operations: [queue_size]BlockRequest,

vdisk_lock: SpinLock,

// these are specific to virtio block devices, e.g. disks,
// described in Section 5.2 of the spec.
pub const BlockRequestType = enum(u32) {
    in = 0, // read from disk
    out = 1, // write to disk
};

// the format of the first descriptor in a disk request.
// to be followed by two more descriptors containing
// the block, and a one-byte status.
pub const BlockRequest = extern struct {
    type: BlockRequestType,
    _reserved: u32,
    sector: u64,
};

pub const StatusBuffer = struct {
    buffer: *Buffer,
    status: u8,
};
