pub fn Queue(comptime queue_size: usize) type {
    return struct {
        pub const size = queue_size;

        comptime {
            if (queue_size == 0 or (queue_size & (queue_size - 1)) != 0)
                @compileError("virtio queue size must be a power of two");
        }

        // a single descriptor, from the spec.
        pub const Descriptor = extern struct {
            address: u64,
            length: u32,
            flags: DescriptorFlags,
            next_index: u16,
        };

        pub const DescriptorFlags = packed struct(u16) {
            next: bool = false, // chained with another descriptor
            write: bool = false, // device writes
            indirect: bool = false,
            _reserved: u13 = 0,
        };

        pub const AvailableFlags = packed struct(u16) {
            no_interrupt: bool = false,
            _reserved: u15 = 0,
        };

        // the (entire) avail ring, from the spec.
        pub const Available = extern struct {
            flags: AvailableFlags,
            idx: u16, // driver will write ring[idx % queue_size] next, is a monotonic counter
            ring: [queue_size]u16, // descriptor numbers of chain heads
            used_event: u16, // only meaningful with event_idx; otherwise padding
        };

        // one entry in the "used" ring, with which the
        // device tells the driver about completed requests.
        pub const UsedElement = extern struct {
            id: u32, // index of start of completed descriptor chain
            length: u32,
        };

        pub const UsedFlags = packed struct(u16) {
            no_notify: bool = false,
            _reserved: u15 = 0,
        };

        pub const Used = extern struct {
            flags: UsedFlags,
            idx: u16, // device increments when it adds a ring[] entry
            ring: [queue_size]UsedElement,
            used_event: u16, // only meaningful with event_idx; otherwise padding
        };
    };
}
