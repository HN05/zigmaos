// flush the TLB.
pub inline fn sfence_vma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

pub const pte_t = usize;
pub const PageTable = [*]usize; // 512 PTEs

pub const pagesize = @import("common").riscv.pagesize;
pub const PGSHIFT = 12; // bits of offset within a page
pub inline fn PGROUNDUP(sz: usize) usize {
    return ((sz) + pagesize - 1) & ~@as(usize, pagesize - 1);
}
pub inline fn PGROUNDDOWN(a: usize) usize {
    return ((a)) & ~@as(usize, pagesize - 1);
}
pub const PTE_V = @as(u32, 1) << 0; // valid
pub const PTE_R = @as(u32, 1) << 1;
pub const PTE_W = @as(u32, 1) << 2;
pub const PTE_X = @as(u32, 1) << 3;
pub const PTE_U = @as(u32, 1) << 4; // user can access

// shift a physical address to the right place for a PTE.
pub inline fn PA2PTE(pa: usize) usize {
    return @as(usize, pa >> 12) << 10;
}
pub inline fn PTE2PA(pte: usize) usize {
    return @as(usize, pte >> 10) << 12;
}
pub inline fn PTE_FLAGS(pte: usize) usize {
    return @as(usize, pte & 0x3FF);
}

// extract the three 9-bit page table indices from a virtual address.
pub const PXMASK = 0x1FF; // 9 bits
pub inline fn PXSHIFT(level: usize) usize {
    return PGSHIFT + @as(usize, 9 * level);
}
pub inline fn PX(level: usize, va: usize) usize {
    return (va >> @as(u6, @intCast(PXSHIFT(level)))) & PXMASK;
}

