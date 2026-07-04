const kernel = @import("root");
const std = @import("std");

const riscv = @import("common").riscv;
const layout = @import("layout.zig");
const pages = @import("pages.zig");

const page_size = pages.page_size;
const PagePointer = pages.PagePointer;
const PageTableIndex = pages.PageTableIndex;

pub const UserAddress = Address(.user);
pub const KernelAddress = Address(.kernel);

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
                .kernel => return self.isBefore(layout.kernelEndAddress()) or !self.isBefore(layout.physical_stop_address),
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
            return Self.fromInt(pages.pageRoundDown(self.toInt()));
        }

        pub fn pageAlignUp(self: Self) Self {
            return Self.fromInt(pages.pageRoundUp(self.toInt()));
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
