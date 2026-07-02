// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig
const std = @import("std");
const csr = @import("csr.zig");
const Register = @import("common").riscv.Register;
const main = @import("main.zig");
const param = @import("common").param;
const memlayout = @import("memlayout.zig");
const log_root = @import("klog.zig");

// a scratch area per CPU for machine-mode timer interrupts.
var timer_scratch: [param.NCPU][5]usize = undefined;

// entry.S needs one stack per CPU.
const stack_size: usize = 4096 * param.NCPU;

// assembly code in kernelvec.S for machine-mode timer interrupt.
extern fn timervec(...) void;

// entry.S needs one stack per CPU.
export var stack0 align(16) = [_]u8{0} ** stack_size;

/// entry.S jumps here in machine mode on stack0.
pub export fn start() void {
    // set M Previous Privilege mode to Supervisor, for mret.
    csr.Mstatus.setMpp(.Supervisor);

    // set M Exception Program Counter to kmain, for mret.
    // requires code_model = .medium
    csr.Mepc.write(@intFromPtr(&main.kmain));

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
pub fn timerinit() void {
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

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    _: ?usize,
) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;
    const panic_log = std.log.scoped(.panic);
    log_root.locking = false;
    panic_log.err("{s}\n", .{msg});
    log_root.panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .debug,
    // Define logFn to override the std implementation
    .logFn = log_root.klogFn,
};
