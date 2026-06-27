const std = @import("std");

const alloc = @import("kalloc.zig");
const ad = @import("address.zig");
const ml = @import("memlayout.zig");
const csr = @import("csr.zig");
const Process = @import("process.zig");

var kernelPagetable: ad.PageTablePtr = undefined;

// flush the TLB.
pub inline fn sfence_vma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

// Create PTEs for virtual addresses starting at va that refer to
// physical addresses starting at pa. va and size might not
// be page-aligned.
// allocate a needed page-table page.
fn virtualMap(
    pgTable: ad.PageTablePtr,
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    permissions: ad.PagePermissions,
    isUser: bool,
) !void {
    if (size == 0) return error.CantMapZeroSize;
    const pageCount = virtualAddress.coveringPages(size);

    for (0..pageCount) |i| {
        const offset = i * ad.page_size;

        const pte = try walk(pgTable, virtualAddress.add(offset), true);
        if (pte.valid) return error.AlreadyMappedPage;
        pte.* = .fromAddress(physicalAddress.add(offset));
        pte.permissions = permissions;
        pte.user = isUser;
        pte.valid = true;
    }
}

pub fn kernelVirtualMap(
    pgTable: ad.PageTablePtr,
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    permissions: ad.PagePermissions,
) !void {
    try virtualMap(pgTable, virtualAddress, physicalAddress, size, permissions, false);
}

pub fn userVirtualMap(
    pgTable: ad.PageTablePtr,
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    permissions: ad.PagePermissions,
) !void {
    try virtualMap(pgTable, virtualAddress, physicalAddress, size, permissions, true);
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

pub fn walk(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddress, doAlloc: bool) WalkError!*ad.PageTableEntry {
    if (virtualAddress.isOutOfRange()) @panic("walk");

    var level: ad.PageTableIndex = .root;
    var currentPgTable = pgTable;
    while (level != .leaf) : (level = level.down().?) {
        const pte = &currentPgTable[virtualAddress.pageIndex(level)];
        if (pte.valid) {
            currentPgTable = pte.asAddress().asPtr(ad.PageTablePtr);
        } else {
            if (!doAlloc) {
                return WalkError.InvalidVirtualAddress;
            }
            const page = alloc.allocPage() orelse return WalkError.OutOfMemory;
            @memset(page, 0);

            currentPgTable = @ptrCast(page);
            pte.* = .fromAddress(.fromPtr(currentPgTable));
            pte.valid = true;
        }
    }

    return &currentPgTable[virtualAddress.pageIndex(.leaf)];
}

fn kernelInitMap(pgTable: ad.PageTablePtr, physicalAddress: ad.KernelAddress, size: usize) void {
    kernelVirtualMap(pgTable, .fromInt(physicalAddress.toInt()), physicalAddress, size, .{ .read = true, .write = true }) catch @panic("initing kernel memory");
}

// Make a direct-map page table for the kernel.
fn kernelMemoryMake() ad.PageTablePtr {
    const page = alloc.allocPage() orelse @panic("no mem available");
    @memset(page, 0);

    const table: ad.PageTablePtr = @ptrCast(page);

    // uart registers
    kernelInitMap(table, ml.uart0_base_address, ad.page_size);

    // virtio mmio disk interface
    kernelInitMap(table, ml.virtio0_base_address, ad.page_size);

    // PLIC
    kernelInitMap(table, ml.plic.base_address, ml.plic.size);

    // map kernel text executable and read-only.
    kernelInitMap(table, ml.kernel_base_address, ml.etextAddress().offsetFrom(ml.kernel_base_address));

    // map kernel data and the physical RAM we'll make use of.
    kernelInitMap(table, ml.etextAddress(), ml.physical_stop_address.offsetFrom(ml.etextAddress()));

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kernelVirtualMap(table, ml.trampoline_virtual_address, ml.trampolinePhysicalAddress(), ad.page_size, .{ .read = true, .execute = true }) catch @panic("initing trampoline");

    // allocate and map a kernel stack for each process.
    Process.mapKernelStacks(table);

    return table;
}

pub fn kernelMemoryInit() void {
    kernelPagetable = kernelMemoryMake();
}

// Switch h/w page table register to the kernel's page table,
// and enable paging.
pub fn kernelMemoryHartInit() void {
    // wait for any previous writes to the page table memory to finish.
    sfence_vma();
    csr.Satp.write(kernelPagetable);
    // flush stale entries from the TLB.
    sfence_vma();
}

// Look up a virtual address, return the physical address,
// Can only be used to look up user pages.
pub fn walkAddr(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddress) !ad.KernelAddress {
    if (virtualAddress.isOutOfRange()) return error.OutOfRange;

    const pte = try walk(pgTable, virtualAddress, false);
    if (!pte.valid) return error.NotValidPage;
    if (!pte.user) return error.NotUserPage;
    return pte.asAddress();
}

// Remove npages of mappings starting from va. va must be
// page-aligned. The mappings must exist.
// Optionally free the physical memory.
pub fn uvmUnmap(pgTable: ad.PageTablePtr, startPage: ad.UserAddress, numPages: usize, doFree: bool) void {
    if (!startPage.isPageAligned()) @panic("uvmUnmap: not aligned");

    for (0..numPages) |i| {
        const virtualAddress = startPage.add(ad.page_size * i);
        const pte = walk(pgTable, virtualAddress, false) catch @panic("uvmUnmap: walk");

        if (!pte.valid) @panic("uvmUnmap: not mapped");

        // leafs have at least one permission set
        if (pte.isBranch()) @panic("uvmUnmap: not a leaf");

        if (doFree) {
            alloc.freePage(pte.asAddress().asPtr(ad.PagePointer)) catch @panic("uvmUnmap: free page");
        }
        pte.* = .{};
    }
}

// create an empty user page table.
pub fn uvmCreate() !ad.PageTablePtr {
    const page = alloc.allocPage() orelse return error.CouldNotGetMem;

    @memset(page, 0);
    return @ptrCast(page);
}

// Load the user initcode into address 0 of pagetable,
// for the very first process.
// sz must be less than a page.
pub fn uvmFirst(pgTable: ad.PageTablePtr, source: []const u8) void {
    if (source.len >= ad.page_size) @panic("uvmfirst: more than a page");

    const page = alloc.allocPage() orelse @panic("out of mem uvmFirst");
    @memset(page, 0);

    userVirtualMap(pgTable, .fromInt(0), .fromPtr(page), ad.page_size, .{ .read = true, .write = true, .execute = true }) catch @panic("could not map first proccess");
    @memmove(page, source);
}

// Allocate PTEs and physical memory to grow process from oldsz to
// newsz, which need not be page aligned.  Returns new size or an error.
pub fn uvmAlloc(pgTable: ad.PageTablePtr, oldSize: usize, newSize: usize, permissions: ad.PagePermissions) !usize {
    if (newSize < oldSize) return oldSize;

    var currentPageVA = ad.UserAddress.fromInt(oldSize).pageAlignUp();

    while (currentPageVA.toInt() < newSize) : (currentPageVA = currentPageVA.add(ad.page_size)) {
        errdefer _ = uvmDealloc(pgTable, currentPageVA.toInt(), oldSize);

        const physicalPage = alloc.allocPage() orelse return error.OutOfMemory;
        @memset(physicalPage, 0);

        errdefer alloc.kfree(physicalPage);

        try userVirtualMap(pgTable, currentPageVA, .fromPtr(physicalPage), ad.page_size, permissions);
    }
    return newSize;
}

// Deallocate user pages to bring the process size from oldsz to
// newsz.  oldsz and newsz need not be page-aligned, nor does newsz
// need to be less than oldsz.  oldsz can be larger than the actual
// process size.  Returns the new process size.
pub fn uvmDealloc(pgTable: ad.PageTablePtr, oldSize: usize, newSize: usize) usize {
    if (newSize >= oldSize) return oldSize;

    const newSizeAligned = ad.pageRoundUp(newSize);
    const oldSizeAligned = ad.pageRoundUp(oldSize);

    if (newSizeAligned < oldSizeAligned) {
        const pageCount = (oldSizeAligned - newSizeAligned) / ad.page_size;
        uvmUnmap(pgTable, .fromInt(newSize), pageCount, true);
    }

    return newSize;
}

// Recursively free page-table pages.
// All leaf mappings must already have been removed.
fn freeWalk(pgTable: ad.PageTablePtr) void {
    // there are 2^9 = 512 PTEs in a page table.
    for (pgTable) |*pte| {
        if (!pte.valid) continue;
        if (pte.isBranch()) {
            // this PTE points to a lower-level page table.
            const child = pte.asAddress().asPtr(ad.PageTablePtr);
            freeWalk(child);
            pte.* = .{};
        } else {
            @panic("freewalk: leaf");
        }
    }
    alloc.freePage(@ptrCast(pgTable)) catch @panic("could not free page freeWalk");
}

// Free user memory pages,
// then free page-table pages.
pub fn uvmFree(pgTable: ad.PageTablePtr, size: usize) void {
    if (size > 0) {
        const sizeAligned = ad.pageRoundUp(size);
        uvmUnmap(pgTable, .fromInt(0), sizeAligned, true);
    }
    freeWalk(pgTable);
}

// Given a parent process's page table, copy
// its memory into a child's page table.
// Copies both the page table and the
// physical memory.
// returns 0 on success, -1 on failure.
// frees any allocated pages on failure.
pub fn uvmCopy(oldTable: ad.PageTablePtr, newTable: ad.PageTablePtr, size: usize) !void {
    var pageAddr: ad.UserAddress = .fromInt(0);
    errdefer uvmUnmap(newTable, .fromInt(0), pageAddr.toInt() / ad.page_size, true);

    while (pageAddr.toInt() < size) : (pageAddr = pageAddr.add(ad.page_size)) {
        const pte = walk(oldTable, pageAddr, false) catch @panic("uvmCopy: pte should exist");

        if (!pte.valid) @panic("uvmCopy: page not present");
        const oldMemory = pte.asAddress().asPtr(ad.PagePointer);

        const newPage = alloc.allocPage() catch return error.OutOfMemory;
        errdefer alloc.freePage(newPage);

        @memmove(newPage, oldMemory);

        if (pte.user) {
            try userVirtualMap(newPage, pageAddr, .fromPtr(newPage), ad.page_size, pte.permissions);
        } else {
            try kernelVirtualMap(newPage, pageAddr, .fromPtr(newPage), ad.page_size, pte.permissions);
        }
    }
}

// mark a PTE invalid for user access.
// used by exec for the user stack guard page.
pub fn uvmClearUser(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddress) void {
    const pte = walk(pgTable, virtualAddress, false) catch @panic("uvmClear");
    pte.user = false;
}

// Copy from kernel to user.
pub fn copyOut(pgTable: ad.PageTablePtr, destVirtualAddress: ad.UserAddress, source: []const u8) !void {
    var destination = destVirtualAddress;
    var remaining = source;

    while (remaining.len > 0) {
        const virtualAligned = destination.pageAlignDown();
        const physicalPage = try walkAddr(pgTable, virtualAligned);
        const physicalDestination = physicalPage.add(destination.pageOffset());

        const byteWriteCount = @min(ad.page_size - destination.pageOffset(), remaining.len);

        @memcpy(physicalDestination.asPtr([*]u8), remaining[0..byteWriteCount]);

        remaining = remaining[byteWriteCount..];
        destination = destination.add(byteWriteCount);
    }
}

// Copy from user to kernel. fills up destination
pub fn copyIn(pgTable: ad.PageTablePtr, destination: []u8, sourceVirtualAddress: ad.UserAddress) !void {
    var source = sourceVirtualAddress;
    var remaining = destination;

    while (remaining.len > 0) {
        const virtualAligned = source.pageAlignDown();
        const physicalPage = try walkAddr(pgTable, virtualAligned);
        const physicalSource = physicalPage.add(source.pageOffset());

        const byteWriteCount = @min(ad.page_size - source.pageOffset(), remaining.len);

        @memcpy(remaining[0..byteWriteCount], physicalSource.asPtr([*]u8));

        remaining = remaining[byteWriteCount..];
        source = source.add(byteWriteCount);
    }
}

// Copy a null-terminated string from user to kernel.
// Copy bytes to dst from virtual address srcva in a given page table,
// until a '\0', or fills destination.
// Not guaranteed to include '\0' and returns str length without it
pub fn copyInString(pgTable: ad.PageTablePtr, destination: []u8, sourceVirtualAddress: ad.UserAddress) !usize {
    var length: usize = 0;
    var remaining = destination;
    var source = sourceVirtualAddress;

    while (remaining.len > 0) {
        const virtualAligned = source.pageAlignDown();
        const physicalPage = try walkAddr(pgTable, virtualAligned);

        const byteWriteCount = @min(ad.page_size - source.pageOffset(), remaining.len);

        const physicalSource = physicalPage.add(source.pageOffset());
        const charSource = physicalSource.asPtr([*]u8);

        for (0..byteWriteCount) |i| {
            remaining[i] = charSource[i];

            // check for '\0'
            if (charSource[i] == 0) return length + i; // not +1 since '\0' does not count
        }
        remaining = remaining[byteWriteCount..];
        source = source.add(byteWriteCount);
        length += byteWriteCount;
    }
    return error.RanOutOfSpace;
}

pub fn copyOutTerminated(pgTable: ad.PageTablePtr, destVirtualAddress: ad.UserAddress, source: []const u8) !void {
    try copyOut(pgTable, destVirtualAddress, source);
    const terminator: [1]u8 = .{0};
    try copyOut(pgTable, destVirtualAddress.add(source.len), &terminator);
}

// Copy to either a user address, or kernel address,
pub fn eitherCopyOut(comptime address_kind: ad.AddressKind, destination: usize, source: []const u8) !void {
    const process = try Process.getCurrentThrows();
    const destination_address = ad.Address(address_kind){.value = destination};

    if (address_kind == .user) {
        try copyOut(process.pageTable, destination_address, source);
    } else {
        @memmove(destination_address.asPtr([*]u8), source);
    }
}

// Copy from either a user address, or kernel address,
pub fn eitherCopyIn(comptime address_kind: ad.AddressKind, source: usize, destination: []const u8) !void {
    const process = try Process.getCurrentThrows();
    const source_address = ad.Address(address_kind){.value = source};

    if (address_kind == .user) {
        try copyIn(process.pageTable, destination, source_address);
    } else {
        @memmove(destination, source_address.asPtr([*]u8));
    }
}
