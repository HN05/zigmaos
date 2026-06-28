//
// virtio device definitions.
// for both the mmio interface, and virtio descriptors.
// only tested with qemu.
//
// the virtio spec:
// https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.pdf
//

const ad = @import("address.zig");
const SpinLock = @import("spinlock.zig");
const Buffer = @import("buffer.zig");
const ml = @import("memlayout.zig");

// virtio mmio control registers, mapped starting at 0x10001000.
// from qemu virtio_mmio.h
pub const mmio = struct {
    pub const Access = packed struct(u2) {
        read: bool = false,
        write: bool = false,

        pub const ro: Access = .{ .read = true };
        pub const wo: Access = .{ .write = true };
        pub const rw: Access = .{ .read = true, .write = true };
    };

    pub const Register = struct {
        offset: usize,
        access: Access,

        pub fn getAddress(self: Register) ad.KernelAddress {
            return ml.virtio0_base_address.add(self.offset);
        }

        pub fn read(self: Register) u32 {
            if (!self.access.read) @panic("tried to read unreadable register");
            return self.getAddress().asPtr(*volatile u32).*;
        }

        pub fn write(self: Register, value: u32) void {
            if (!self.access.write) @panic("tried to write to unrwritable register");
            self.getAddress().asPtr(*volatile u32).* = value;
        }
    };

    pub const magic_value = Register{ .offset = 0x000, .access = .ro }; // 0x74726976
    pub const version = Register{ .offset = 0x004, .access = .ro }; // version; should be 2
    pub const device_id = Register{ .offset = 0x008, .access = .ro }; // device type; 1 is net, 2 is disk
    pub const vendor_id = Register{ .offset = 0x00c, .access = .ro }; // 0x554d4551

    pub const Features = packed struct(u32) {
        // device feature bits
        _reserved0: u5 = 0,

        blk_ro: bool = false, // Disk is read-only

        _reserved1: u1 = 0,

        blk_scsi: bool = false, // Supports SCSI command passthru

        _reserved2: u3 = 0,

        blk_config_wce: bool = false, // Writeback mode available in config
        blk_mq: bool = false, // Supports more than one virtqueue

        _reserved3: u14 = 0,

        any_layout: bool = false,
        ring_indirect_desc: bool = false,
        ring_event_idx: bool = false,

        _reserved4: u2 = 0,

        const device_register = Register{ .offset = 0x010, .access = .ro };
        const driver_register = Register{ .offset = 0x020, .access = .wo };

        pub fn readFeatures() Features {
            return @bitCast(device_register.read());
        }

        pub fn writeFeatures(features: Features) void {
            driver_register.write(@bitCast(features));
        }
    };

    pub const queue_sel = Register{ .offset = 0x030, .access = .wo }; // select queue
    pub const queue_num_max = Register{ .offset = 0x034, .access = .ro }; // max size of current queue
    pub const queue_num = Register{ .offset = 0x038, .access = .wo }; // size of current queue
    pub const queue_ready = Register{ .offset = 0x044, .access = .rw }; // ready bit
    pub const queue_notify = Register{ .offset = 0x050, .access = .wo };

    pub const interrupt_status = Register{ .offset = 0x060, .access = .ro };
    pub const interrupt_ack = Register{ .offset = 0x064, .access = .wo };

    // status register bits, from qemu virtio_config.h
    pub const Status = packed struct(u32) {
        acknowledge: bool = false,
        driver: bool = false,
        driver_ok: bool = false,
        features_ok: bool = false,
        _reserved: u28 = 0,

        pub const register = Register{ .offset = 0x070, .access = .rw };

        pub fn readStatus() Status {
            return @bitCast(Status.register.read());
        }

        pub fn writeStatus(status: Status) void {
            Status.register.write(@bitCast(status));
        }
    };

    pub const AddressRegister = struct {
        low: Register,
        high: Register,

        pub fn init(offset: usize, access: Access) AddressRegister {
            return .{ .low = Register{ .offset = offset, .access = access }, .high = Register{ .offset = offset + 4, .access = access } };
        }

        pub fn write(self: AddressRegister, address: ad.KernelAddress) void {
            const value = address.toInt();
            self.low.write(@truncate(value));
            self.high.write(@truncate(value >> 32));
        }
    };

    pub const queue_descriptor_table = AddressRegister.init(0x080, .wo); // physical address for descriptor table
    pub const driver_desc = AddressRegister.init(0x090, .wo); // physical address for available ring
    pub const device_desc = AddressRegister.init(0x0a0, .wo); // physical address for used ring
};

// this many virtio descriptors.
// must be a power of two.
pub const num_virtio_descriptors = 8;

// a single descriptor, from the spec.
const QueueDescriptor = extern struct {
    address: u64,
    length: u32,
    flags: QueueDescriptorFlags,
    next: u16,
};

const QueueDescriptorFlags = packed struct(u16) {
    next: bool = false, // chained with another descriptor
    write: bool = false, // device writes
    indirect: bool = false,
    _reserved: u13 = 0,
};

// the (entire) avail ring, from the spec.
const QueueAvailable = extern struct {
    flags: u16, // always zero
    idx: u16, // driver will write ring[idx] next
    ring: [num_virtio_descriptors]u16, // descriptor numbers of chain heads
    unused: u16,
};

// one entry in the "used" ring, with which the
// device tells the driver about completed requests.
const QueueUsedElement = extern struct {
    id: u32, // index of start of completed descriptor chain
    length: u32,
};

const QueueUsed = extern struct {
    flags: u16, // always zero
    idx: u16, // device increments when it adds a ring[] entry
    ring: [num_virtio_descriptors]QueueUsedElement,
};

// these are specific to virtio block devices, e.g. disks,
// described in Section 5.2 of the spec.
const BlockRequestType = enum(u32) {
    in = 0, // read from disk
    out = 1, // write to disk
};

// the format of the first descriptor in a disk request.
// to be followed by two more descriptors containing
// the block, and a one-byte status.
const BlockRequest = extern struct {
    type: BlockRequestType,
    _reserved: u32,
    sector: u64,
};

const StatusBuffer = struct {
    buffer: *Buffer,
    status: u8,
};

const Disk = struct {
    // a set (not a ring) of DMA descriptors, with which the
    // driver tells the device where to read and write individual
    // disk operations. there are NUM descriptors.
    // most commands consist of a "chain" (a linked list) of a couple of
    // these descriptors.
    desc: *QueueDescriptor,

    // a ring in which the driver writes descriptor numbers
    // that the driver would like the device to process
    // includes the head descriptor of each chain. the ring has
    // NUM elements.
    available: *QueueAvailable,

    // a ring in which the device writes descriptor numbers that
    // the device has finished processing (just the head of each chain).
    // there are NUM used ring entries.
    used: *QueueUsed,

    // our own book-keeping.
    free: [num_virtio_descriptors]bool, // is a descriptor free?
    used_idx: u16, // we've looked this far in used[2..NUM].

    // track info about in-flight operations,
    // for use when completion interrupt arrives.
    // indexed by first descriptor index of chain.
    info: StatusBuffer[num_virtio_descriptors],

    // disk command headers.
    // one-for-one with descriptors, for convenience.
    operations: [num_virtio_descriptors]BlockRequest,

    vdisk_lock: SpinLock,
};
