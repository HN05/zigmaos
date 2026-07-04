const allocator = @import("allocation.zig");
const ad = @import("address.zig");
const ml = @import("layout.zig");
const vm = @import("virtual_memory.zig");
const km = @import("kernel_memory.zig");
const pg = @import("pages.zig");

pub fn map(
    pgTable: pg.PageTablePtr,
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    permissions: pg.PagePermissions,
) !void {
    try vm.map(pgTable, virtualAddress, physicalAddress, size, permissions, .user);
}

pub const unmap = vm.unmap;

// Create a user page table for a given process, with no user memory,
// but with trampoline and trapframe pages.
pub fn createPagetable(trapframe_address: ad.KernelAddress) !pg.PageTablePtr {
    // An empty page table.
    const pageTable: pg.PageTablePtr = @ptrCast(allocator.allocPage(.zeroed) orelse return error.OutOfMem);
    errdefer free(pageTable, 0);

    // map the trampoline code (for system call return)
    // at the highest user virtual address.
    // only the supervisor uses it, on the way
    // to/from user space, so not PTE_U.
    try vm.map(pageTable, ml.trampoline_virtual_address, ml.trampolinePhysicalAddress(), pg.page_size, vm.MappingKind.code.permissions(), .kernel);
    errdefer unmap(pageTable, ml.trampoline_virtual_address, 1, false);

    // map the trapframe page just below the trampoline page, for
    // trampoline.S.
    try vm.map(pageTable, ml.trapframe_virtual_address, trapframe_address, pg.page_size, vm.MappingKind.data.permissions(), .kernel);
    errdefer unmap(pageTable, ml.trapframe_virtual_address, 1, false);

    return pageTable;
}


// Load the user initcode into address 0 of pagetable,
// for the very first process.
// sz must be less than a page.
pub fn loadFirstProcess(pgTable: pg.PageTablePtr, source: []const u8) void {
    if (source.len >= pg.page_size) @panic("uvmfirst: more than a page");

    const page = allocator.allocPageForce(.zeroed);

    map(pgTable, .fromInt(0), .fromPtr(page), pg.page_size, .{ .read = true, .write = true, .execute = true }) catch @panic("could not map first proccess");
    @memmove(page, source);
}

// Allocate PTEs and physical memory to grow process from oldsz to
// newsz, which need not be page aligned.  Returns new size or an error.
pub fn alloc(pgTable: pg.PageTablePtr, oldSize: usize, newSize: usize, permissions: pg.PagePermissions) !usize {
    if (newSize < oldSize) return oldSize;

    var currentPageVA = ad.UserAddress.fromInt(oldSize).pageAlignUp();

    while (currentPageVA.toInt() < newSize) : (currentPageVA = currentPageVA.add(pg.page_size)) {
        errdefer _ = dealloc(pgTable, currentPageVA.toInt(), oldSize);

        const physicalPage = allocator.allocPage(.zeroed) orelse return error.OutOfMemory;

        errdefer allocator.freePage(physicalPage) catch @panic("could not free allocated memory");

        try map(pgTable, currentPageVA, .fromPtr(physicalPage), pg.page_size, permissions);
    }
    return newSize;
}

// Deallocate user pages to bring the process size from oldsz to
// newsz.  oldsz and newsz need not be page-aligned, nor does newsz
// need to be less than oldsz.  oldsz can be larger than the actual
// process size.  Returns the new process size.
pub fn dealloc(pgTable: pg.PageTablePtr, oldSize: usize, newSize: usize) usize {
    if (newSize >= oldSize) return oldSize;

    const newSizeAligned = pg.pageRoundUp(newSize);
    const oldSizeAligned = pg.pageRoundUp(oldSize);

    if (newSizeAligned < oldSizeAligned) {
        const pageCount = (oldSizeAligned - newSizeAligned) / pg.page_size;
        unmap(pgTable, .fromInt(newSizeAligned), pageCount, true);
    }

    return newSize;
}

// Recursively free page-table pages.
// All leaf mappings must already have been removed.
fn freeWalk(pgTable: pg.PageTablePtr) void {
    // there are 2^9 = 512 PTEs in a page table.
    for (pgTable) |*pte| {
        if (!pte.valid) continue;
        if (pte.isBranch()) {
            // this PTE points to a lower-level page table.
            const child = pte.asAddress().asPtr(pg.PageTablePtr);
            freeWalk(child);
            pte.* = .{};
        } else {
            @panic("freewalk: leaf");
        }
    }
    allocator.freePage(@ptrCast(pgTable)) catch @panic("could not free page freeWalk");
}

// mark a PTE invalid for user access.
// used by exec for the user stack guard page.
pub fn clearUser(pgTable: pg.PageTablePtr, virtualAddress: ad.UserAddress) void {
    const pte = vm.walk(pgTable, virtualAddress, false) catch @panic("uvmClear");
    pte.user = false;
}

// Free user memory pages,
// then free page-table pages.
fn free(pgTable: pg.PageTablePtr, size: usize) void {
    if (size > 0) {
        const sizeAligned = pg.pageRoundUp(size);
        unmap(pgTable, .fromInt(0), sizeAligned / pg.page_size, true);
    }
    freeWalk(pgTable);
}

// Free a process's page table, and free the
// physical memory it refers to.
pub fn freePageTable(pageTable: pg.PageTablePtr, size: usize) void {
    unmap(pageTable, ml.trampoline_virtual_address, 1, false);
    unmap(pageTable, ml.trapframe_virtual_address, 1, false);
    free(pageTable, size);
}

// Given a parent process's page table, copy
// its memory into a child's page table.
// Copies both the page table and the
// physical memory.
// returns 0 on success, -1 on failure.
// frees any allocated pages on failure.
pub fn copyPageTable(oldTable: pg.PageTablePtr, newTable: pg.PageTablePtr, size: usize) !void {
    var pageAddr: ad.UserAddress = .fromInt(0);
    errdefer unmap(newTable, .fromInt(0), pageAddr.toInt() / pg.page_size, true);

    while (pageAddr.toInt() < size) : (pageAddr = pageAddr.add(pg.page_size)) {
        const pte = vm.walk(oldTable, pageAddr, false) catch @panic("uvmCopy: pte should exist");

        if (!pte.valid) @panic("uvmCopy: page not present");
        const oldMemory = pte.asAddress().asPtr(pg.PagePointer);

        const newPage = allocator.allocPage(.garbage) orelse return error.OutOfMemory;
        errdefer allocator.freePage(newPage) catch @panic("could not free allocated page");

        @memmove(newPage, oldMemory);

        const address_space: vm.AddressSpace = if (pte.user) .user else .kernel;
        try vm.map(newTable, pageAddr, .fromPtr(newPage), pg.page_size, pte.permissions, address_space);
    }
}

// Look up a virtual address, return the physical address,
// Can only be used to look up user pages.
pub fn translateAddress(pgTable: pg.PageTablePtr, virtualAddress: ad.UserAddress) !ad.KernelAddress {
    if (virtualAddress.isOutOfRange()) return error.OutOfRange;

    const pte = try vm.walk(pgTable, virtualAddress, false);
    if (!pte.valid) return error.NotValidPage;
    if (!pte.user) return error.NotUserPage;
    return pte.asAddress();
}

