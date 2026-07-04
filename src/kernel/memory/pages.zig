const common = @import("common");

const ad = @import("address.zig");
const vm = @import("virtual_memory.zig");

const KernelAddress = ad.KernelAddress;

pub const page_size = common.riscv.page_size;

// custom logic since it is power of 2
pub fn pageRoundDown(val: usize) usize {
    return val & ~@as(usize, page_size - 1);
}

pub fn pageRoundUp(val: usize) usize {
    if (val & (page_size - 1) == 0) return val;
    return (val + page_size - 1) & ~@as(usize, page_size - 1);
}

pub const PagePointer = *align(page_size) [page_size]u8;
pub const ConstPagePointer = *align(page_size) const [page_size]u8;

pub const MappingKind = vm.MappingKind;
pub const PagePermissions = packed struct(u3) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
};

pub const PageTableIndex = enum(u2) {
    leaf = 0, // VPN[0]
    branch = 1, // VPN[1]
    root = 2, // VPN[2]

    pub fn down(self: PageTableIndex) ?PageTableIndex {
        if (self == .leaf) return null;
        return @enumFromInt(@intFromEnum(self) - 1);
    }
};

pub const PageTableEntry = packed struct(usize) {
    valid: bool = false,
    permissions: PagePermissions = .{},
    user: bool = false,
    global: bool = false,
    accessed: bool = false,
    dirty: bool = false,

    // reserved for supervisor
    reservedFlag1: bool = false,
    reservedFlag2: bool = false,

    ppn: u44 = 0, // page number
    reserved: u10 = 0, // must be zero

    pub fn isBranch(self: *PageTableEntry) bool {
        return self.permissions == PagePermissions{}; // r, w and x are not set for branch
    }

    pub fn asAddress(self: *PageTableEntry) KernelAddress {
        return KernelAddress.fromInt(@as(usize, self.ppn) << 12);
    }

    pub fn fromAddress(address: KernelAddress) PageTableEntry {
        return .{ .ppn = @intCast(address.toInt() >> 12) };
    }
};

pub const page_table_entries_per_page = page_size / @sizeOf(PageTableEntry);
pub const PageTable = [page_table_entries_per_page]PageTableEntry; // 512 PTEs in one page
pub const PageTablePtr = *align(page_size) PageTable;
