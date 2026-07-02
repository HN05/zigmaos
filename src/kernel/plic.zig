//
// the riscv Platform Level Interrupt Controller (PLIC).
//
const std = @import("std");
const ml = @import("memlayout.zig");
const execution = @import("execution.zig");
const getHart = execution.Cpu.getCurrentId;

pub const Irq = enum(u32) {
    uart = ml.uart0_irq,
    virtio = ml.virtio0_irq,
    null = 0,
    _,
};

pub fn init() void {
    // set desired IRQ priorities non-zero (otherwise disabled).
    ml.plic.priorityRegister(ml.uart0_irq).* = 1;
    ml.plic.priorityRegister(ml.virtio0_irq).* = 1;
}

pub fn initHart() void {
    const hart = getHart();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    ml.plic.supervisorEnableRegister(hart).* = (1 << ml.uart0_irq) | (1 << ml.virtio0_irq);

    // set this hart's S-mode priority threshold to 0.
    ml.plic.supervisorPriorityThresholdRegister(hart).* = 0;
}

// ask the PLIC what interrupt we should serve.
pub fn claim() Irq {
    const hart = getHart();
    const irq = ml.plic.supervisorClaimCompleteRegister(hart).*;
    return @enumFromInt(irq);
}

// tell the PLIC we've served this IRQ.
pub fn complete(irq: Irq) void {
    const hart = getHart();
    ml.plic.supervisorClaimCompleteRegister(hart).* = @intFromEnum(irq);
}
