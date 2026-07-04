const ad = @import("address.zig");
const pg = @import("pages.zig");
const alloc = @import("allocation.zig");

pub const AddressSpace = enum { kernel, user };
pub const MappingKind = enum {
    code,
    data,

    pub fn permissions(self: MappingKind) pg.PagePermissions {
        return .{ .read = true, .write = self == .data, .execute = self == .code };
    } 
};

// Create PTEs for virtual addresses starting at va that refer to
// physical addresses starting at pa. va and size might not
// be page-aligned.
// allocate a needed page-table page.
pub fn map(
    pgTable: pg.PageTablePtr,
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    permissions: pg.PagePermissions,
    address_space: AddressSpace,
) !void {
    if (size == 0) return error.CantMapZeroSize;
    const pageCount = virtualAddress.coveringPages(size);

    for (0..pageCount) |i| {
        const offset = i * pg.page_size;

        const pte = try walk(pgTable, virtualAddress.add(offset), true);
        if (pte.valid) return error.AlreadyMappedPage;
        pte.* = .fromAddress(physicalAddress.add(offset));
        pte.permissions = permissions;
        pte.user = address_space == .user;
        pte.valid = true;
    }
}

// Remove npages of mappings starting from va. va must be
// page-aligned. The mappings must exist.
// Optionally free the physical memory.
pub fn unmap(pgTable: pg.PageTablePtr, startPage: ad.UserAddress, numPages: usize, doFree: bool) void {
    if (!startPage.isPageAligned()) @panic("uvmUnmap: not aligned");

    for (0..numPages) |i| {
        const virtualAddress = startPage.add(pg.page_size * i);
        const pte = walk(pgTable, virtualAddress, false) catch @panic("uvmUnmap: walk");

        if (!pte.valid) @panic("uvmUnmap: not mapped");

        // leafs have at least one permission set
        if (pte.isBranch()) @panic("uvmUnmap: not a leaf");

        if (doFree) {
            alloc.freePage(pte.asAddress().asPtr(pg.PagePointer)) catch @panic("uvmUnmap: free page");
        }
        pte.* = .{};
    }
}

// Return the address of the PTE in page table pagetable
// that corresponds to virtual address va.  If alloc!=0,
// create any required page-table pages.
//
// The risc-v Sv39 scheme has three levels of page-table
// pages. A page-table page contains 512 64-bit PTEs.
// A 64-bit virtual address is split into five fields:
//   39..63 -- must be zero.
//   30..38 -- 9 bits of level-2 index.
//   21..29 -- 9 bits of level-1 index.
//   12..20 -- 9 bits of level-0 index.
//    0..11 -- 12 bits of byte offset within the page.
pub const WalkError = error{
    InvalidVirtualAddress,
    OutOfMemory,
};
pub fn walk(pgTable: pg.PageTablePtr, virtualAddress: ad.UserAddress, doAlloc: bool) WalkError!*pg.PageTableEntry {
    if (virtualAddress.isOutOfRange()) @panic("walk");

    var level: pg.PageTableIndex = .root;
    var currentPgTable = pgTable;
    while (level != .leaf) : (level = level.down().?) {
        const pte = &currentPgTable[virtualAddress.pageIndex(level)];
        if (pte.valid) {
            currentPgTable = pte.asAddress().asPtr(pg.PageTablePtr);
        } else {
            if (!doAlloc) {
                return WalkError.InvalidVirtualAddress;
            }
            const page = alloc.allocPage(.zeroed) orelse return WalkError.OutOfMemory;

            currentPgTable = @ptrCast(page);
            pte.* = .fromAddress(.fromPtr(currentPgTable));
            pte.valid = true;
        }
    }

    return &currentPgTable[virtualAddress.pageIndex(.leaf)];
}
