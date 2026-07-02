const kernel = @import("root");
const std = @import("std");

const riscv = @import("common").riscv;
const memlayout = @import("memlayout.zig");
const kalloc = @import("kalloc.zig");

pub const page_size = riscv.page_size;

// custom logic since it is power of 2
pub fn pageRoundDown(val: usize) usize {
    return val & ~@as(usize, page_size - 1);
}

pub fn pageRoundUp(val: usize) usize {
    if (val & (page_size - 1) == 0) return val;
    return (val + page_size - 1) & ~@as(usize, page_size - 1);
}

pub const UserAddress = Address(.user);
pub const KernelAddress = Address(.kernel);

pub const PagePointer = *align(page_size) [page_size]u8;
pub const ConstPagePointer = *align(page_size) const [page_size]u8;

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

pub const page_table_entry_count = page_size / @sizeOf(PageTableEntry);
pub const PageTable = [page_table_entry_count]PageTableEntry; // 512 PTEs in one page
pub const PageTablePtr = *align(page_size) PageTable;

pub const AddressKind = enum {
    user,
    kernel,
};

pub const AnyAddress = union(AddressKind) {
    user: UserAddress,
    kernel: KernelAddress,

    pub fn fromPtr(pointer: *const anyopaque) AnyAddress {
        return .{ .kernel = .fromPtr(pointer) };
    }

    pub fn kind(self: AnyAddress) AddressKind {
        return std.meta.activeTag(self);
    }

    pub fn add(self: AnyAddress, offset: usize) AnyAddress {
        return switch (self) {
            .user => |addr| .{ .user = addr.add(offset) },
            .kernel => |addr| .{ .kernel = addr.add(offset) },
        };
    }
};

// is constant, a new value is always returned, never modified in place
pub fn Address(comptime addressKind: AddressKind) type {
    return struct {
        value: usize,

        const Self = @This();

        pub const kind = addressKind;

        pub fn fromInt(value: usize) Self {
            return .{ .value = value };
        }

        pub fn toInt(self: Self) usize {
            return self.value;
        }

        pub fn asPtr(self: Self, comptime Ptr: type) Ptr {
            comptime {
                if (kind == .user) {
                    @compileError("can't dereference user pointer");
                }
                if (@typeInfo(Ptr) != .pointer) {
                    @compileError("asPtr expects a pointer type");
                }
            }
            return @ptrFromInt(self.toInt());
        }

        pub fn fromPtr(ptr: *const anyopaque) Self {
            comptime {
                if (kind == .user) @compileError("can't init from userpointer");
            }
            return Self.fromInt(@intFromPtr(ptr));
        }

        pub fn deref(self: Self, comptime T: type) T {
            return asPtr(self, *T).*;
        }

        pub fn isOutOfRange(self: Self) bool {
            const val = self.toInt();
            switch (kind) {
                .user => return val >= riscv.max_virtual_address,
                .kernel => return self.isBefore(memlayout.kernelEndAddress()) or !self.isBefore(memlayout.physical_stop_address),
            }
        }

        pub fn add(self: Self, offset: usize) Self {
            return Self.fromInt(self.toInt() + offset);
        }

        pub fn sub(self: Self, offset: usize) Self {
            return Self.fromInt(self.toInt() - offset);
        }

        pub fn offsetFrom(self: Self, address: Self) usize {
            return self.value - address.value;
        }

        pub fn isAfter(self: Self, address: Self) bool {
            return self.value > address.value;
        }

        pub fn isBefore(self: Self, address: Self) bool {
            return self.value < address.value;
        }

        pub fn isEqual(self: Self, address: Self) bool {
            return self.value == address.value;
        }

        pub fn isPageAligned(self: Self) bool {
            return self.pageOffset() == 0;
        }

        pub fn pageAlignDown(self: Self) Self {
            return Self.fromInt(pageRoundDown(self.toInt()));
        }

        pub fn pageAlignUp(self: Self) Self {
            return Self.fromInt(pageRoundUp(self.toInt()));
        }

        pub fn pagePtrAlignDown(self: Self) PagePointer {
            return @ptrFromInt(self.pageAlignDown().toInt());
        }

        pub fn pagePtrAlignUp(self: Self) PagePointer {
            return @ptrFromInt(self.pageAlignUp().toInt());
        }

        pub fn pageOffset(self: Self) usize {
            return self.toInt() & (page_size - 1);
        }

        pub fn pageIndex(self: Self, level: PageTableIndex) u9 {
            const levelInt: usize = @intFromEnum(level);
            const shift: u6 = @intCast(12 + 9 * levelInt);
            return @intCast((self.toInt() >> shift) & 0x1ff);
        }

        pub fn coveringPages(self: Self, len: usize) usize {
            const firstPage = self.pageAlignDown().toInt();
            const lastPage = self.add(len - 1).pageAlignDown().toInt();
            return ((lastPage - firstPage) / page_size) + 1;
        }
    };
}
