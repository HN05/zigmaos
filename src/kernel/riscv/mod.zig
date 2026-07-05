pub const csr = @import("csr.zig");
pub const plic = @import("plic.zig");

pub inline fn memoryFence() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

pub inline fn fullMemoryBarrier() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}
