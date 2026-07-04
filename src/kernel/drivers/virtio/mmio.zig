const kernel = @import("root");

const ml = kernel.memory.layout;
const KernelAddress = kernel.memory.address.KernelAddress;

// virtio mmio control registers, mapped starting at 0x10001000.
// from qemu virtio_mmio.h
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

    pub fn getAddress(self: Register) KernelAddress {
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
pub const expected_magic_value: u32 = 0x74726976; // "virt"

pub const version = Register{ .offset = 0x004, .access = .ro };
pub const expected_version: u32 = 2;

pub const DeviceId = enum(u32) {
    none = 0,
    network = 1,
    disk = 2,
    _,

    const register = Register{ .offset = 0x008, .access = .ro };

    pub fn read() DeviceId {
        return @enumFromInt(register.read());
    }
};

pub const vendor_id = Register{ .offset = 0x00c, .access = .ro };
pub const expected_vendor_id: u32 = 0x554d4551; // "QEMU"

pub const Features = packed struct(u32) {
    device_specific: DeviceSpecific = .{ .raw = 0 },

    notify_on_empty: bool = false, // legacy

    _reserved0: u2 = 0,

    any_layout: bool = false, // legacy
    ring_indirect_desc: bool = false,
    ring_event_idx: bool = false,

    _reserved1: u2 = 0,

    pub const device_register = Register{ .offset = 0x010, .access = .ro };
    pub const driver_register = Register{ .offset = 0x020, .access = .wo };

    pub fn write(features: Features) void {
        driver_register.write(@bitCast(features));
    }

    pub fn read() Features {
        return @bitCast(device_register.read());
    }

    pub const DeviceSpecific = packed union {
        raw: u24,
        block: Block,
    };

    pub const Block = packed struct(u24) {
        barrier: bool = false, // legacy: request barriers

        size_max: bool = false, // size_max field valid
        seg_max: bool = false, // seg_max field valid

        _reserved0: u1 = 0,

        geometry: bool = false, // geometry field valid
        ro: bool = false, // disk is read-only
        blk_size: bool = false, // blk_size field valid

        scsi: bool = false, // legacy: SCSI packet commands

        _reserved1: u1 = 0,

        flush: bool = false, // flush command support
        topology: bool = false, // topology field valid
        config_wce: bool = false, // writeback mode available in config
        mq: bool = false, // multiple virtqueues

        discard: bool = false, // discard command support
        write_zeroes: bool = false, // write zeroes command support

        _reserved2: u9 = 0,
    };
};

pub const Queue = struct {
    const select_register = Register{ .offset = 0x030, .access = .wo }; // select queue
    const num_max_register = Register{ .offset = 0x034, .access = .ro }; // max size of current queue
    const num_register = Register{ .offset = 0x038, .access = .wo }; // size of current queue
    const ready_register = Register{ .offset = 0x044, .access = .rw }; // ready bit
    const notify_register = Register{ .offset = 0x050, .access = .wo };

    pub fn select(index: u32) void {
        select_register.write(index);
    }

    pub fn maxSize() u32 {
        return num_max_register.read();
    }

    pub fn setSize(size: u32) void {
        num_register.write(size);
    }

    pub fn isReady() bool {
        return ready_register.read() != 0;
    }

    pub fn setReady(value: bool) void {
        ready_register.write(if (value) 1 else 0);
    }

    pub fn notifyDevice(index: u32) void {
        notify_register.write(index);
    }
};

pub const InterruptStatus = packed struct(u2) {
    used_buffer_notification: bool = false,
    configuration_change: bool = false,

    pub const register = Register{ .offset = 0x060, .access = .ro };
    pub const ack_register = Register{ .offset = 0x064, .access = .wo };

    pub fn read() InterruptStatus {
        const smallInt: u2 = @truncate(register.read());
        return @bitCast(smallInt);
    }

    pub fn ackStatus(status: InterruptStatus) void {
        const bits: u2 = @bitCast(status);
        ack_register.write(bits);
    }

    pub fn ack() void {
        read().ackStatus();
    }
};

// status register bits, from qemu virtio_config.h
pub const Status = packed struct(u8) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    _reserved: u2 = 0,
    device_needs_reset: bool = false,
    failed: bool = false,

    pub const register = Register{ .offset = 0x070, .access = .rw };

    pub fn read() Status {
        const smallInt: u8 = @truncate(register.read());
        return @bitCast(smallInt);
    }

    pub fn write(status: Status) void {
        const bits: u8 = @bitCast(status);
        register.write(bits);
    }
};

pub const AddressRegister = struct {
    low: Register,
    high: Register,

    pub fn init(offset: usize, access: Access) AddressRegister {
        return .{ .low = Register{ .offset = offset, .access = access }, .high = Register{ .offset = offset + 4, .access = access } };
    }

    pub fn write(self: AddressRegister, address: KernelAddress) void {
        const value = address.toInt();
        self.low.write(@truncate(value));
        self.high.write(@truncate(value >> 32));
    }
};

pub const queue_descriptor_table = AddressRegister.init(0x080, .wo); // physical address for descriptor table
pub const driver_desc = AddressRegister.init(0x090, .wo); // physical address for available ring
pub const device_desc = AddressRegister.init(0x0a0, .wo); // physical address for used ring
