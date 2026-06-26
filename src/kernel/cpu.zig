const common = @import("common");
const param = common.param;
const Register = common.riscv.Register;
const csr = @import("csr.zig");
const Process = @import("process.zig");
const Context = Process.Context;

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/stat.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
    @cInclude("kernel/fs.h");
    @cInclude("kernel/sleeplock.h");
    @cInclude("kernel/file.h");
    @cInclude("kernel/fcntl.h");
});

const Cpu = @This();
pub var table: [param.NCPU]Cpu = undefined;

// Per-CPU state.
runningProcess: ?*Process, // The process running on this cpu, or null.
context: Context, // swtch() here to enter scheduler().
pushDepth: usize, // Depth of push_off() nesting.
interruptsEnabled: bool, // Were interrupts enabled before push_off()?

// Must be called with interrupts disabled,
// to prevent race with process being moved
// to a different CPU.
pub fn getCurrentId() usize {
    return Register.read(.tp);
}

pub fn getCurrent() *Cpu {
    return &table[getCurrentId()];
}

