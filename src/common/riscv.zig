pub const Register = @import("registers.zig").UserRegister;
pub const page_size = 4096; // bytes per page

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
pub const max_virtual_address = @as(usize, 1) << (9 + 9 + 9 + 12 - 1);

// Saved registers for context switches.
// used by swtch.S
pub const Context = extern struct {
    ra: u64 = 0,
    sp: u64 = 0,

    // callee-saved
    s0: u64 = 0,
    s1: u64 = 0,
    s2: u64 = 0,
    s3: u64 = 0,
    s4: u64 = 0,
    s5: u64 = 0,
    s6: u64 = 0,
    s7: u64 = 0,
    s8: u64 = 0,
    s9: u64 = 0,
    s10: u64 = 0,
    s11: u64 = 0,
};

