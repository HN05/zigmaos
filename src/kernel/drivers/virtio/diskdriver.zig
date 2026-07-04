//
// driver for qemu's virtio disk device.
// uses qemu's mmio interface to virtio.
//
// qemu ... -drive file=fs.img,if=none,format=raw,id=x0 -device virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0
//

const kernel = @import("root");

const Disk = @import("disk.zig");
const mmio = @import("mmio.zig");

const mem = kernel.memory;
const alloc = mem.allocation;
const ml = mem.layout;
const ad = mem.address;
const Queue = Disk.DiskQueue;
const execution = kernel.execution;
const fs = kernel.filesystem;
const Buffer = fs.Buffer;
const page_size = mem.pages.page_size;

var disk: Disk = undefined;

pub const queue_number = 0;

pub fn init() void {
    if (mmio.magic_value.read() != mmio.expected_magic_value) @panic("wrong magic number virtio");
    if (mmio.version.read() != mmio.expected_version) @panic("wrong version number virtio");
    if (mmio.vendor_id.read() != mmio.expected_vendor_id) @panic("wrong vendor_id virtio");
    if (mmio.DeviceId.read() != .disk) @panic("virtio device is not a disk");

    // reset device
    var status: mmio.Status = .{};
    status.write();

    // set ACKNOWLEDGE status bit
    status.acknowledge = true;
    status.write();

    // set DRIVER status bit
    status.driver = true;
    status.write();

    // negotiate features
    const features = mmio.Features{}; // set all features to off
    features.write();

    // tell device that feature negotiation is complete.
    status.features_ok = true;
    status.write();

    // re-read status to ensure FEATURES_OK is set.
    status = .read();
    if (!status.features_ok) @panic("virtio disk features_ok unset");

    // initialize queue 0.
    mmio.Queue.select(queue_number);

    // ensure queue 0 is not in use.
    if (mmio.Queue.isReady()) @panic("virtio disk should not be ready");

    // check maximum queue size.
    const max = mmio.Queue.maxSize();
    if (max == 0) @panic("virtio disk has no queue of queue_number");
    if (max < Disk.queue_size) @panic("virtio disk max queue too short");

    // allocate and zero queue memory.
    //  TODO: allocate memory more effectivly
    comptime {
        if (@sizeOf([Queue.size]Queue.Descriptor) > page_size)
            @compileError("descriptor table does not fit in one page");
        if (@sizeOf(Queue.Available) > page_size)
            @compileError("available ring does not fit in one page");
        if (@sizeOf(Queue.Used) > page_size)
            @compileError("used ring does not fit in one page");
    }
    const descriptor: *[Queue.size]Queue.Descriptor = @ptrCast(alloc.allocPageForce(.zeroed));
    const available: *Queue.Available = @ptrCast(alloc.allocPageForce(.zeroed));
    const used: *Queue.Used = @ptrCast(alloc.allocPageForce(.zeroed));

    // set queue size.
    mmio.Queue.setSize(Queue.size);

    // write physical addresses.
    mmio.queue_descriptor_table.write(.fromPtr(descriptor));
    mmio.driver_desc.write(.fromPtr(available));
    mmio.device_desc.write(.fromPtr(used));

    // queue is ready.
    mmio.Queue.setReady(true);

    // init disk
    disk = .{
        .descriptor = descriptor,
        .available = available,
        .used = used,
        .vdisk_lock = .init(.spin, "virtio disk"),
        .used_idx = 0,
        .operations = undefined,
        .free = undefined,
        .info = undefined,
    };

    // all NUM descriptors start out unused.
    @memset(&disk.free, true);

    // tell device we're completely ready.
    status.driver_ok = true;
    status.write();

    // plic.c and trap.c arrange for interrupts from VIRTIO0_IRQ.
}

// find a free descriptor, mark it non-free, return its index.
fn allocDescriptor() !u16 {
    for (disk.free, 0..) |is_free, index| {
        if (is_free) {
            disk.free[index] = false;
            return @truncate(index);
        }
    }
    return error.NoFreeDescriptor;
}

// mark a descriptor as free.
fn freeDescriptor(index: u16) void {
    if (index >= disk.free.len) @panic("freeDescriptor out of range");
    if (disk.free[index]) @panic("freeDescriptor already free");

    const descriptor = &disk.descriptor[index];
    descriptor.address = 0;
    descriptor.length = 0;
    descriptor.flags = .{};
    descriptor.next_index = 0;
    disk.free[index] = true;

    execution.scheduler.wakeup(&disk.free[0]);
}

// free a chain of descriptors.
fn freeDescriptorChain(index: u16) void {
    var current_index = index;
    while (true) {
        const flags = disk.descriptor[current_index].flags;
        const next = disk.descriptor[current_index].next_index;
        freeDescriptor(current_index);
        if (flags.next) {
            current_index = next;
        } else {
            break;
        }
    }
}

// allocate descriptors for the slice (they need not be contiguous).
// disk transfers always use three descriptors.
fn allocDescriptorsSlice(descriptor_destination: []u16) !void {
    for (descriptor_destination, 0..) |*descriptor, index| {
        descriptor.* = allocDescriptor() catch {
            for (descriptor_destination[0..index]) |free_descriptor| {
                freeDescriptor(free_descriptor);
            }
            return error.CouldNotAllocateDescriptor;
        };
    }
}

inline fn fullMemoryBarrier() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

pub fn read(buffer: *Buffer) void {
    readOrWrite(buffer, false);
}

pub fn write(buffer: *Buffer) void {
    readOrWrite(buffer, true);
}

fn readOrWrite(buffer: *Buffer, do_write: bool) void {
    const sector = buffer.block.number * (fs.block_size / Disk.sector_size);

    disk.vdisk_lock.acquire();
    defer disk.vdisk_lock.release();

    // the spec's Section 5.2 says that legacy block operations use
    // three descriptors: one for type/reserved/sector, one for the
    // data, one for a 1-byte status result.

    // allocate the three descriptors.
    var descriptor_indexes: [3]u16 = undefined;
    while (true) {
        allocDescriptorsSlice(&descriptor_indexes) catch {
            disk.vdisk_lock.sleepOn(&disk.free[0]);
            continue;
        };
        break;
    }

    // format the three descriptors.
    // qemu's virtio-blk.c reads them.
    const block_request_0 = &disk.operations[descriptor_indexes[0]];
    block_request_0.* = .{
        .type = if (do_write) .out else .in, // out is write, in is read
        .sector = sector,
    };

    const descriptor0 = &disk.descriptor[descriptor_indexes[0]];
    descriptor0.address = @intFromPtr(block_request_0);
    descriptor0.length = @sizeOf(Disk.BlockRequest);
    descriptor0.flags = .{ .next = true };
    descriptor0.next_index = descriptor_indexes[1];

    const descriptor1 = &disk.descriptor[descriptor_indexes[1]];
    descriptor1.address = @intFromPtr(&buffer.data);
    descriptor1.length = fs.block_size;
    descriptor1.flags = .{ .write = !do_write, .next = true }; // if write is set it will write data into buffer
    descriptor1.next_index = descriptor_indexes[2];

    disk.info[descriptor_indexes[0]].status = .pending; // device writes .okay on success

    const descriptor2 = &disk.descriptor[descriptor_indexes[2]];
    descriptor2.address = @intFromPtr(&disk.info[descriptor_indexes[0]].status); // pass address of status to device
    descriptor2.length = 1;
    descriptor2.flags = .{ .write = true }; // device writes the status
    descriptor2.next_index = 0;

    // record struct buf for disk interrupt.
    buffer.disk_owned = true;
    disk.info[descriptor_indexes[0]].buffer = buffer;

    // tell the device the first index in our chain of descriptors.
    disk.available.ring[disk.available.idx % Queue.size] = descriptor_indexes[0];

    fullMemoryBarrier();

    // tell the device another avail ring entry is available.
    disk.available.idx +%= 1; // not % queue size, is monotonic, but % no prevent overflow

    fullMemoryBarrier();

    mmio.Queue.notifyDevice(queue_number);

    // Wait for virtio_disk_intr() to say request has finished.
    while (buffer.disk_owned) {
        disk.vdisk_lock.sleepOn(buffer);
    }

    disk.info[descriptor_indexes[0]].buffer = null;
    freeDescriptorChain(descriptor_indexes[0]);
}

pub fn interrupt() void {
    disk.vdisk_lock.acquire();
    defer disk.vdisk_lock.release();

    // the device won't raise another interrupt until we tell it
    // we've seen this interrupt, which the following line does.
    // this may race with the device writing new entries to
    // the "used" ring, in which case we may process the new
    // completion entries in this interrupt, and have nothing to do
    // in the next interrupt, which is harmless.
    mmio.InterruptStatus.ack();

    fullMemoryBarrier();

    // the device increments disk.used->idx when it
    // adds an entry to the used ring.
    while (disk.used_idx != disk.used.idx) {
        fullMemoryBarrier();
        const id = disk.used.ring[disk.used_idx % Queue.size].id;

        if (disk.info[id].status != .ok) @panic("virtio disk interrupt status");

        const buffer = disk.info[id].buffer.?;
        buffer.disk_owned = false; // disk is done with buf
        execution.scheduler.wakeup(buffer);

        disk.used_idx +%= 1;
    }
}
