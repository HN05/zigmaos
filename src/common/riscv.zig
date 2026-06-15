pub const registers = @import("registers.zig").UserRegister;
pub const pagesize = 4096; // bytes per page

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
pub const max_virtual_address = @as(usize, 1) << (9 + 9 + 9 + 12 - 1);

