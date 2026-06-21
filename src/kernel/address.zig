const std = @import("std");

const riscv = @import("common").riscv;
const memlayout = @import("memlayout.zig");
const kalloc = @import("kalloc.zig");

pub const page_size = riscv.page_size;

pub const UserAddr = Addr(.user);
pub const KernAddr = Addr(.kernel);

pub const PagePtr = *align(page_size) [page_size]u8;
pub const ConstPagePtr = *align(page_size) const [page_size]u8;

pub const PageSlice = []align(page_size) u8;
pub const ConstPageSlice = []align(page_size) const u8;

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

    pub fn asAddress(self: *PageTableEntry) KernAddr {
        return KernAddr.fromInt(@as(usize, self.ppn) << 12);
    }

    pub fn fromAddress(address: KernAddr) PageTableEntry {
        return .{ .ppn = @intCast(address.toInt() >> 12) };
    }

    pub fn asPagePtr(self: *PageTableEntry) PagePtr {
        return asAddress(self).asPtr(PagePtr);
    }

    pub fn fromPagePtr(pagePtr: PagePtr) PageTableEntry {
        return .fromAddress(.fromPtr(pagePtr));
    }
};

pub const page_table_entry_count = page_size / @sizeOf(PageTableEntry);
pub const PageTable = [page_table_entry_count]PageTableEntry; // 512 PTEs in one page
pub const PageTablePtr = *align(page_size) PageTable;

pub const AddrKind = enum {
    user,
    kernel,
};

pub fn Addr(comptime kind: AddrKind) type {
    return struct {
        value: usize,

        const Self = @This();

        pub const addr_kind = kind;

        pub fn fromInt(value: usize) Self {
            return .{ .value = value };
        }

        pub fn toInt(self: Self) usize {
            return self.value;
        }

        pub fn asPtr(self: Self, comptime Ptr: type) Ptr {
            if (addr_kind == .user) {
                @panic("can't dereference user pointer");
            }

            comptime {
                if (@typeInfo(Ptr) != .pointer) {
                    @compileError("asPtr expects a pointer type");
                }
            }
            return @ptrFromInt(self.toInt());
        }

        pub fn fromPtr(ptr: *anyopaque) Self {
            return Self.fromInt(@intFromPtr(ptr));
        }

        pub fn deref(self: Self, comptime T: type) T {
            return asPtr(self, *T).*;
        }

        pub fn isOutOfRange(self: Self) bool {
            const val = self.toInt();
            switch (addr_kind) {
                .user => return val >= riscv.max_virtual_address,
                .kernel => return val < @intFromPtr(kalloc.end) or val >= memlayout.PHYSTOP,
            }
        }

        pub fn add(self: Self, offset: usize) Self {
            return Self.fromInt(self.toInt() + offset);
        }

        pub fn sub(self: Self, offset: usize) Self {
            return Self.fromInt(self.toInt() - offset);
        }

        pub fn isPageAligned(self: Self) bool {
            return self.pageOffset() == 0;
        }

        pub fn pageAlignDown(self: Self) Self {
            return Self.fromInt(self.toInt() & ~@as(usize, page_size - 1));
        }

        pub fn pageAlignUp(self: Self) Self {
            const value = self.toInt();
            if (value & (page_size - 1) == 0) return self;
            return Self.fromInt((value + page_size - 1) & ~@as(usize, page_size - 1));
        }

        pub fn pagePtrAlignDown(self: Self) PagePtr {
            return @ptrFromInt(self.pageAlignDown().toInt());
        }

        pub fn pagePtrAlignUp(self: Self) PagePtr {
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
