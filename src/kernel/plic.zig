//
// the riscv Platform Level Interrupt Controller (PLIC).
//
const std = @import("std");
const ml = @import("memlayout.zig");

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
});

fn getcpu() usize {
    return @intCast(c.cpuid());
}

pub fn init() void {
    // set desired IRQ priorities non-zero (otherwise disabled).
    ml.PLIC_PRIORITY(ml.UART0_IRQ).* = 1;
    ml.PLIC_PRIORITY(ml.VIRTIO0_IRQ).* = 1;
}

pub fn initHart() void {
    const hart = getcpu();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    ml.PLIC_SENABLE(hart).* = (1 << ml.UART0_IRQ) | (1 << ml.VIRTIO0_IRQ);
    // set this hart's S-mode priority threshold to 0.
    ml.PLIC_SPRIORITY(hart).* = 0;
}

// ask the PLIC what interrupt we should serve.
pub fn claim() u32 {
    const hart = getcpu();
    const irq = ml.PLIC_SCLAIM(hart);
    return irq.*;
}

// tell the PLIC we've served this IRQ.
pub fn complete(irq: u32) void {
    const hart = getcpu();
    ml.PLIC_SCLAIM(hart).* = irq;
}
