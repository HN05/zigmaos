const std = @import("std");

const c = @cImport({
    @cInclude("kernel/param.h");
    @cInclude("kernel/types.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/elf.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/fs.h");
});

const alloc = @import("kalloc.zig");
const ad = @import("address.zig");
const ml = @import("memlayout.zig");
const csr = @import("csr.zig");

var kernelPagetable: ad.PageTablePtr = undefined;

extern const etext: anyopaque; // kernel.ld sets this to end of kernel code.

extern const trampoline: anyopaque;

// flush the TLB.
pub inline fn sfence_vma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

// Create PTEs for virtual addresses starting at va that refer to
// physical addresses starting at pa. va and size might not
// be page-aligned.
// allocate a needed page-table page.
fn virtualMap(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddr, physicalAddress: ad.KernAddr, size: usize, permissions: ad.PagePermissions, isUser: bool) void {
    if (size == 0) @panic("ke: kerenelVirtualMap");
    const pageCount = virtualAddress.coveringPages(size);

    for (0..pageCount) |i| {
        const offset = i * ad.page_size;

        const pte = walk(pgTable, virtualAddress.add(offset), true) catch @panic("initing kernel memory error");
        if (pte.valid) @panic("kernelVirtualMap: already mapped page");
        pte.* = .fromAddress(physicalAddress.add(offset));
        pte.permissions = permissions;
        pte.user = isUser;
        pte.valid = true;
    }
}

pub fn kernelVirtualMap(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddr, physicalAddress: ad.KernAddr, size: usize, permissions: ad.PagePermissions) void {
    virtualMap(pgTable, virtualAddress, physicalAddress, size, permissions, false);
}

pub fn userVirtualMap(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddr, physicalAddress: ad.KernAddr, size: usize, permissions: ad.PagePermissions) void {
    virtualMap(pgTable, virtualAddress, physicalAddress, size, permissions, true);
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

pub fn walk(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddr, doAlloc: bool) WalkError!*ad.PageTableEntry {
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

// Make a direct-map page table for the kernel.
fn kernelMemoryMake() ad.PageTablePtr {
    const page = alloc.allocPage() orelse @panic("no mem available");
    @memset(page, 0);

    const table: ad.PageTablePtr = @ptrCast(page);
    const etextAddr = @intFromPtr(&etext);
    const trampolineAddr = @intFromPtr(&trampoline);

    // uart registers
    kernelVirtualMap(table, .fromInt(ml.UART0), .fromInt(ml.UART0), ad.page_size, .{ .read = true, .write = true });

    // virtio mmio disk interface
    kernelVirtualMap(table, .fromInt(ml.VIRTIO0), .fromInt(ml.VIRTIO0), ad.page_size, .{ .read = true, .write = true });

    // PLIC
    kernelVirtualMap(table, .fromInt(ml.PLIC), .fromInt(ml.PLIC), ml.PLIC_SIZE, .{ .read = true, .write = true });

    // map kernel text executable and read-only.
    kernelVirtualMap(table, .fromInt(ml.KERNBASE), .fromInt(ml.KERNBASE), etextAddr - ml.KERNBASE, .{ .read = true, .execute = true });

    // map kernel data and the physical RAM we'll make use of.
    kernelVirtualMap(table, .fromInt(etextAddr), .fromInt(etextAddr), ml.PHYSTOP - etextAddr, .{ .read = true, .write = true });

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kernelVirtualMap(table, .fromInt(ml.TRAMPOLINE), .fromInt(trampolineAddr), ad.page_size, .{ .read = true, .execute = true });

    // allocate and map a kernel stack for each process.
    c.proc_mapstacks(@intFromPtr(table));

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
pub fn walkAddr(pgTable: ad.PageTablePtr, virtualAddress: ad.UserAddr) !ad.KernAddr {
    if (virtualAddress.isOutOfRange()) return error.OutOfRange;

    const pte = try walk(pgTable, virtualAddress, false);
    if (!pte.valid) return error.NotValidPage;
    if (!pte.user) return error.NotUserPage;
    return pte.asAddress();
}

// Remove npages of mappings starting from va. va must be
// page-aligned. The mappings must exist.
// Optionally free the physical memory.
pub fn uvmUnmap(pgTable: ad.PageTablePtr, startPage: ad.UserAddr, numPages: usize, doFree: bool) void {
    if (!startPage.isPageAligned()) @panic("uvmUnmap: not aligned");

    for (0..numPages) |i| {
        const virtualAddress = startPage.add(ad.page_size * i);
        const pte = walk(pgTable, virtualAddress, false) catch @panic("uvmUnmap: walk");

        if (!pte.valid) @panic("uvmUnmap: not mapped");

        // leafs have at least one permission set
        if (pte.isBranch()) @panic("uvmUnmap: not a leaf");

        if (doFree) {
            alloc.freePage(pte.asAddress().asPtr(ad.PagePtr)) catch @panic("uvmUnmap: free page");
        }
        pte.* = .{};
    }
}

// create an empty user page table.
pub fn uvmCreate() !ad.PageTablePtr {
    const page = try alloc.allocPage();

    @memset(page, 0);
    return @ptrCast(page);
}

// Load the user initcode into address 0 of pagetable,
// for the very first process.
// sz must be less than a page.
pub fn uvmFirst(pgTable: ad.PageTablePtr, source: ad.KernAddr, size: usize) void {
    if (size >= ad.page_size) @panic("uvmfirst: more than a page");

    const page = alloc.kalloc() catch @panic("out of mem uvmFirst");
    @memset(page, 0);

    userVirtualMap(pgTable, .fromInt(0), .fromPtr(page), ad.page_size, .{ .read = true, .write = true, .execute = true });
    @memmove(page[0..size], source.asPtr([*]const u8));
}

// Allocate PTEs and physical memory to grow process from oldsz to
// newsz, which need not be page aligned.  Returns new size or an error.
pub fn uvmAlloc(pgTable: ad.PageTablePtr, oldSize: usize, newSize: usize, permissions: ad.PagePermissions) !usize {
    if (newSize < oldSize) return oldSize;

    var currentPageVA: ad.UserAddr = .fromInt(oldSize).pageAlignUp();

    while (currentPageVA.toInt() < newSize) : (currentPageVA.add(ad.page_size)) {
        errdefer uvmDealloc(pgTable, currentPageVA.toInt(), oldSize);

        const physicalPage = alloc.allocPage() orelse return error.OutOfMemory;
        @memset(physicalPage, 0);

        errdefer alloc.kfree(physicalPage);

        userVirtualMap(pgTable, currentPageVA, .fromPtr(physicalPage), ad.page_size, permissions);
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
        uvmUnmap(pgTable, newSize, pageCount, true);
    }

    return newSize;
}

// Recursively free page-table pages.
// All leaf mappings must already have been removed.
fn freeWalk(pgTable: ad.PageTablePtr) void {
    // there are 2^9 = 512 PTEs in a page table.
    for (pgTable.*) |*pte| {
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
    alloc.freePage(@ptrCast(pgTable));
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


// // Given a parent process's page table, copy
// // its memory into a child's page table.
// // Copies both the page table and the
// // physical memory.
// // returns 0 on success, -1 on failure.
// // frees any allocated pages on failure.
// int
// uvmcopy(pagetable_t old, pagetable_t new, uint64 sz)
// {
//   pte_t *pte;
//   uint64 pa, i;
//   uint flags;
//   char *mem;
//
//   for(i = 0; i < sz; i += PGSIZE){
//     if((pte = walk(old, i, 0)) == 0)
//       panic("uvmcopy: pte should exist");
//     if((*pte & PTE_V) == 0)
//       panic("uvmcopy: page not present");
//     pa = PTE2PA(*pte);
//     flags = PTE_FLAGS(*pte);
//     if((mem = kalloc()) == 0)
//       goto err;
//     memmove(mem, (char*)pa, PGSIZE);
//     if(mappages(new, i, PGSIZE, (uint64)mem, flags) != 0){
//       kfree(mem);
//       goto err;
//     }
//   }
//   return 0;
//
//  err:
//   uvmunmap(new, 0, i / PGSIZE, 1);
//   return -1;
// }
//
// // mark a PTE invalid for user access.
// // used by exec for the user stack guard page.
// void
// uvmclear(pagetable_t pagetable, uint64 va)
// {
//   pte_t *pte;
//
//   pte = walk(pagetable, va, 0);
//   if(pte == 0)
//     panic("uvmclear");
//   *pte &= ~PTE_U;
// }
//
// void* custom_memcpy(void* dst, const void* src, int n) {
//   typedef uint64 __attribute__((__may_alias__)) u64;
//   // copy until word aligned (64-bit)
//   char* dst_pos = dst;
//   const char* src_pos = src;
//   while ((n > 0) && ((u64)dst_pos % 8 != 0) && ((u64)src_pos % 8 != 0)) {
//     *dst_pos++ = *src_pos++;
//     n--;
//   }
//   // copy 64-bit words
//   u64* dst_pos64 = (u64*)dst_pos;
//   const u64* src_pos64 = (const u64*)src_pos;
//   while (n >= 8) {
//     *dst_pos64++ = *src_pos64++;
//     n -= 8;
//   }
//   // copy remaining bytes
//   dst_pos = (char*)dst_pos64;
//   src_pos = (const char*)src_pos64;
//   while (n > 0) {
//     *dst_pos++ = *src_pos++;
//     n--;
//   }
//   return dst;
// }
//
// // Copy from kernel to user.
// // Copy len bytes from src to virtual address dstva in a given page table.
// // Return 0 on success, -1 on error.
// int
// copyout(pagetable_t pagetable, uint64 dstva, char *src, uint64 len)
// {
//   uint64 n, va0, pa0;
//
//   while(len > 0){
//     va0 = PGROUNDDOWN(dstva);
//     pa0 = walkaddr(pagetable, va0);
//     if(pa0 == 0)
//       return -1;
//     n = PGSIZE - (dstva - va0);
//     if(n > len)
//       n = len;
//     custom_memcpy((void *)(pa0 + (dstva - va0)), src, n);
//
//     len -= n;
//     src += n;
//     dstva = va0 + PGSIZE;
//   }
//   return 0;
// }
//
// // Copy from user to kernel.
// // Copy len bytes to dst from virtual address srcva in a given page table.
// // Return 0 on success, -1 on error.
// int
// copyin(pagetable_t pagetable, char *dst, uint64 srcva, uint64 len)
// {
//   uint64 n, va0, pa0;
//
//   while(len > 0){
//     va0 = PGROUNDDOWN(srcva);
//     pa0 = walkaddr(pagetable, va0);
//     if(pa0 == 0)
//       return -1;
//     n = PGSIZE - (srcva - va0);
//     if(n > len)
//       n = len;
//     custom_memcpy(dst, (void *)(pa0 + (srcva - va0)), n);
//
//     len -= n;
//     dst += n;
//     srcva = va0 + PGSIZE;
//   }
//   return 0;
// }
//
// // Copy a null-terminated string from user to kernel.
// // Copy bytes to dst from virtual address srcva in a given page table,
// // until a '\0', or max.
// // Return 0 on success, -1 on error.
// int
// copyinstr(pagetable_t pagetable, char *dst, uint64 srcva, uint64 max)
// {
//   uint64 n, va0, pa0;
//   int got_null = 0;
//
//   while(got_null == 0 && max > 0){
//     va0 = PGROUNDDOWN(srcva);
//     pa0 = walkaddr(pagetable, va0);
//     if(pa0 == 0)
//       return -1;
//     n = PGSIZE - (srcva - va0);
//     if(n > max)
//       n = max;
//
//     char *p = (char *) (pa0 + (srcva - va0));
//     while(n > 0){
//       if(*p == '\0'){
//         *dst = '\0';
//         got_null = 1;
//         break;
//       } else {
//         *dst = *p;
//       }
//       --n;
//       --max;
//       p++;
//       dst++;
//     }
//
//     srcva = va0 + PGSIZE;
//   }
//   if(got_null){
//     return 0;
//   } else {
//     return -1;
//   }
// }
