const common = @import("common");
const param = common.param;
const lk = @import("spinlock.zig");
const ad = @import("address.zig");
const ml = @import("memlayout.zig");
const alloc = @import("kalloc.zig");
const mem = @import("memory.zig");
const Cpu = @import("cpu.zig");
const interrupts = @import("interrupts.zig");

pub const c = @cImport({
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

pub var processTable: [param.NPROC]Process = blk: {
    var table: [processTable.len]Process = undefined;
    for (0..table.len) |index| {
        table[index] = .{ .kernelStackAddress = ml.KSTACK(index) };
    }
    break :blk table;
};

pub var initialProcess: *Process = undefined;
pub var nextProcessId: u32 = 1;
pub var processIdLock: lk.SpinLock = .{ .name = "nextpid" };

extern const trampoline: anyopaque;

// helps ensure that wakeups of wait()ing
// parents are not lost. helps obey the
// memory model when using p->parent.
// must be acquired before any p->lock.
pub var waitLock: lk.SpinLock = .{ .name = "wait_lock" };

// Allocate a page for each process's kernel stack.
// Map it high in memory, followed by an invalid
// guard page.
pub fn mapKernelStacks(kernelPageTable: ad.PageTablePtr) void {
    inline for (0..processTable.len) |index| {
        const virtualAddress = ml.KSTACK(index);

        inline for (0..ml.KSTACK_PAGENUM) |i| {
            const virtual_page_address = virtualAddress.add(i * ad.page_size);

            const physical_page = alloc.allocPage() orelse @panic("could not map stacks: kalloc");
            mem.kernelVirtualMap(kernelPageTable, virtual_page_address, .fromPtr(physical_page), ad.page_size, .{ .write = true, .read = true });
        }
    }
}

// per-process data for the trap handling code in trampoline.S.
// sits in a page by itself just under the trampoline page in the
// user page table. not specially mapped in the kernel page table.
// uservec in trampoline.S saves user registers in the trapframe,
// then initializes registers from the trapframe's
// kernel_sp, kernel_hartid, kernel_satp, and jumps to kernel_trap.
// usertrapret() and userret in trampoline.S set up
// the trapframe's kernel_*, restore user registers from the
// trapframe, switch to the user page table, and enter user space.
// the trapframe includes callee-saved user registers like s0-s11 because the
// return-to-user path via usertrapret() doesn't return through
// the entire kernel call stack.
pub const TrapFrame = extern struct {
    kernel_satp: u64, // kernel page table
    kernel_sp: u64, // top of process's kernel stack
    kernel_trap: u64, // usertrap()
    epc: u64, // saved user program counter
    kernel_hartid: u64, // saved kernel tp
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    s0: u64,
    s1: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
};

// Saved registers for kernel context switches.
pub const Context = extern struct {
    ra: u64,
    sp: u64,

    // callee-saved
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
};

pub const ProcessState = enum {
    unused,
    used,
    sleeping,
    runnable,
    running,
    zombie,
};

const Process = @This();
// Per-process state
lock: lk.SpinLock = .{ .name = "proc" },

// p->lock must be held when using these:
state: ProcessState = .unused,
sleepingOnChannel: ?*anyopaque = undefined, // If non-null, sleeping on channel
isKilled: bool = undefined,
exitStatus: u32 = undefined, // Exit status to be returned to parent's wait
id: u32 = undefined, // process id

// wait_lock must be held when using this:
parentProcess: ?*Process = undefined, // null for root process

// these are private to the process, so p->lock need not be held.
kernelStackAddress: ad.UserAddress, // Virtual address of kernel stack
size: usize = undefined, // Size of process memory (bytes)
pageTable: ad.PageTablePtr = undefined, // User page table
topFreeVirtualPage: ad.UserAddress = .fromInt(ml.TRAPFRAME - 2 * ad.page_size), // The highest free user virtual mem page. Starts at TRAPFRAME - 2*PGSIZE and goes down as pages are used.
trapFrame: *TrapFrame = undefined, // data page for trampoline.S
context: Context = undefined, // swtch() here to run process
openFiles: [param.NOFILE]*c.struct_file = undefined, // Open files
currentWorkingDirectory: *c.struct_inode = undefined,
name: [16]u8 = undefined, // for debugging
ownedRingbufsCount: usize = undefined, // Count of ringbufs owned by this process

pub fn getCurrent() ?*Process {
    interrupts.pushOff();
    const cpu = Cpu.getCurrent();
    const proc = cpu.runningProcess;
    interrupts.popOff();
    return proc;
}
