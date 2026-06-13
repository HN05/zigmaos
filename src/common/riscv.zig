pub const pagesize = 4096; // bytes per page


// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
pub const max_virtual_address = @as(usize, 1) << (9 + 9 + 9 + 12 - 1);


pub inline fn r_sp() usize {
    return asm volatile ("mv a0, sp"
        : [ret] "={a0}" (-> usize),
    );
}

// read and write tp, the thread pointer, which xv6 uses to hold
// this core's hartid (core number), the index into cpus[].
pub inline fn r_tp() usize {
    return asm volatile ("mv a0, tp"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_tp(tp: usize) void {
    asm volatile ("mv tp, a0"
        :
        : [tp] "{a0}" (tp),
    );
}

pub inline fn r_ra() usize {
    return asm volatile ("mv a0, ra"
        : [ret] "={a0}" (-> usize),
    );
}

