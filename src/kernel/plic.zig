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

// cast as ptr to a u32
inline fn castptr(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

fn getcpu() usize {
    return @intCast(c.cpuid());
}

pub fn init() void {
  // set desired IRQ priorities non-zero (otherwise disabled).
  castptr(ml.PLIC + ml.UART0_IRQ*4).* = 1;
  castptr(ml.PLIC + ml.VIRTIO0_IRQ*4).* = 1;
}

pub fn inithart() void {
    const hart = getcpu();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    castptr(ml.PLIC_SENABLE(hart)).* = (1 << ml.UART0_IRQ) | (1 << ml.VIRTIO0_IRQ);
    // set this hart's S-mode priority threshold to 0.
    castptr(ml.PLIC_SPRIORITY(hart)).* = 0;
}

// ask the PLIC what interrupt we should serve.
export fn plic_claim() c_int {
    const hart = getcpu();
    const irq = castptr(ml.PLIC_SCLAIM(hart));
    return @intCast(irq.*);
}

// tell the PLIC we've served this IRQ.
export fn plic_complete(irq: c_int) void {
    const hart = getcpu();
    castptr(ml.PLIC_SCLAIM(hart)).* = @intCast(irq);
}

// converted from: 
// // #include "types.h"
// #include "param.h"
// #include "memlayout.h"
// #include "riscv.h"
// #include "defs.h"
//
// //
// // the riscv Platform Level Interrupt Controller (PLIC).
// //
//
// void
// plicinit(void)
// {
//   // set desired IRQ priorities non-zero (otherwise disabled).
//   *(uint32*)(PLIC + UART0_IRQ*4) = 1;
//   *(uint32*)(PLIC + VIRTIO0_IRQ*4) = 1;
// }
//
// void
// plicinithart(void)
// {
//   int hart = cpuid();
//
//   // set enable bits for this hart's S-mode
//   // for the uart and virtio disk.
//   *(uint32*)PLIC_SENABLE(hart) = (1 << UART0_IRQ) | (1 << VIRTIO0_IRQ);
//
//   // set this hart's S-mode priority threshold to 0.
//   *(uint32*)PLIC_SPRIORITY(hart) = 0;
// }
//
// // ask the PLIC what interrupt we should serve.
// int
// plic_claim(void)
// {
//   int hart = cpuid();
//   int irq = *(uint32*)PLIC_SCLAIM(hart);
//   return irq;
// }
//
// // tell the PLIC we've served this IRQ.
// void
// plic_complete(int irq)
// {
//   int hart = cpuid();
//   *(uint32*)PLIC_SCLAIM(hart) = irq;
// }
//
