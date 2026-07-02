const std = @import("std");
const common = @import("common");

const csr = @import("csr.zig");
const main = @import("main.zig");
const memlayout = @import("memlayout.zig");

const Register = common.riscv.Register;
const param = common.param;

// a scratch area per CPU for machine-mode timer interrupts.
var timer_scratch: [param.NCPU][5]usize = undefined;

// assembly code in kernelvec.S for machine-mode timer interrupt.
extern fn timervec(...) void;

/// entry.S jumps here in machine mode on stack0.
pub fn start() void {
    // set M Previous Privilege mode to Supervisor, for mret.
    csr.Mstatus.setMpp(.Supervisor);

    // set M Exception Program Counter to kmain, for mret.
    // requires code_model = .medium
    csr.Mepc.write(@intFromPtr(&main.kernelMain));

    // disable paging for now.
    csr.Satp.writeInt(0);

    // delegate all interrupts and exceptions to supervisor mode.
    csr.Medeleg.setAllFlags();
    csr.Mideleg.setAllFlags();

    csr.Sie.chain()
        .set(.SEIE)
        .set(.SSIE)
        .set(.STIE)
        .commit();

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    csr.Pmpaddr0.allowAllPhysicalMemory();
    csr.Pmpcfg0.chain()
        .set(.read)
        .set(.write)
        .set(.execute)
        .set(.NAPOT)
        .commit();

    // ask for clock interrupts.
    timerinit();

    // keep each CPU's hartid in its tp register, for cpuid().
    const id = csr.Mhartid.read();
    Register.write(.tp, id);

    asm volatile ("mret");
}

/// arrange to receive timer interrupts.
/// they will arrive in machine mode at
/// at timervec in kernelvec.S,
/// which turns them into software interrupts for
/// devintr() in trap.c.
fn timerinit() void {
    // each CPU has a separate source of timer interrupts.
    const id = csr.Mhartid.read();

    // ask the CLINT for a timer interrupt.
    const interval = 1000000; // cycles; about 1/10th second in qemu.
    memlayout.clint_mtimecmp(id).* = memlayout.clint_mtime.* + interval;

    // prepare information in scratch[] for timervec.
    // scratch[0..2] : space for timervec to save registers.
    // scratch[3] : address of CLINT MTIMECMP register.
    // scratch[4] : desired interval (in cycles) between timer interrupts.
    var scratch = timer_scratch[id];
    scratch[3] = @intFromPtr(memlayout.clint_mtimecmp(id));
    scratch[4] = interval;
    csr.Mscratch.write(@intFromPtr(&scratch));

    // set the machine-mode trap handler.
    csr.Mtvec.write(@intFromPtr(&timervec));

    // enable machine-mode interrupts.
    csr.Mstatus.set(.Machine_interrupts_enable);

    // enable machine-mode timer interrupts.
    csr.Mie.set(.MTIE);
}
