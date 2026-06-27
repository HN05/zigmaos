const common = @import("common");
const param = common.param;
const Context = common.riscv.Context;
const lk = @import("spinlock.zig");
const ad = @import("address.zig");
const ml = @import("memlayout.zig");
const alloc = @import("kalloc.zig");
const mem = @import("memory.zig");
const Cpu = @import("cpu.zig");
const interrupts = @import("interrupts.zig");
const std = @import("std");
const ringbuf = @import("ringbuf.zig");
const print = @import("klog.zig").print;
const scheduler = @import("scheduler.zig");

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
    var table: [param.NPROC]Process = undefined;
    for (0..table.len) |index| {
        table[index] = .{ .kernelStackAddress = ml.KSTACK(index) };
    }
    break :blk table;
};

pub var initialProcess: *Process = undefined;
pub var nextProcessId: std.atomic.Value(u32) = .init(1);

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

        inline for (0..ml.kernel_stack_page_count) |i| {
            const virtual_page_address = virtualAddress.add(i * ad.page_size);

            const physical_page = alloc.allocPage() orelse @panic("could not map stacks: kalloc");
            mem.kernelVirtualMap(kernelPageTable, virtual_page_address, .fromPtr(physical_page), ad.page_size, .{ .write = true, .read = true }) catch @panic("could not map process kernel stack");
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

    pub fn asPagePointer(self: *TrapFrame) ad.PagePointer {
        return @ptrCast(@alignCast(self));
    }
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
sleepingOnChannel: ?*anyopaque = null, // If non-null, sleeping on channel
isKilled: bool = false,
exitStatus: u32 = 0, // Exit status to be returned to parent's wait
pid: u32 = 0, // process id

// wait_lock must be held when using this:
parentProcess: ?*Process = null, // null for root process

// these are private to the process, so p->lock need not be held.
kernelStackAddress: ad.UserAddress, // Virtual address of kernel stack
size: usize = 0, // Size of process memory (bytes)
pageTable: ad.PageTablePtr = undefined, // User page table
topFreeVirtualPage: ad.UserAddress = ml.trapframe_virtual_address.sub(2 * ad.page_size), // The highest free user virtual mem page. Starts at TRAPFRAME - 2*PGSIZE and goes down as pages are used.
trapFrame: *TrapFrame = undefined, // data page for trampoline.S
context: Context = undefined, // switchContext() here to run process
openFiles: [param.NOFILE]?*c.struct_file = [_]?*c.struct_file{null} ** param.NOFILE, // Open files
currentWorkingDirectory: *c.struct_inode = undefined,
nameBuffer: [16]u8 = undefined, // for debugging
nameLength: u4 = 0,
ownedRingbufsCount: usize = 0, // Count of ringbufs owned by this process
allocatedTrapFrame: bool = false,
allocatedPageTable: bool = false,

pub fn getCurrentForce() *Process {
    return getCurrent() orelse @panic("getCurrentForce: no process running");
}

pub fn getCurrent() ?*Process {
    interrupts.pushOff();
    const cpu = Cpu.getCurrent();
    const proc = cpu.runningProcess;
    interrupts.popOff();
    return proc;
}

fn allocProcessId() u32 {
    return nextProcessId.fetchAdd(1, .monotonic);
}

fn allocFoundProcess(process: *Process) !void {
    errdefer free(process);
    errdefer process.lock.release();

    process.pid = allocProcessId();
    process.state = .used;

    // Allocate a trapframe page.
    const trap_page = alloc.allocPage() orelse return error.FailedMemAllocate;
    process.trapFrame = @ptrCast(trap_page);
    process.allocatedTrapFrame = true;

    // An empty user page table.
    process.pageTable = try createPagetable(process);
    process.allocatedPageTable = true;

    // Set up new context to start executing at forkret,
    // which returns to user space.
    process.context = .{};
    process.context.ra = @intFromPtr(&forkReturn);
    process.context.sp = process.kernelStackAddress.add(ml.kernel_stack_page_count * ad.page_size).toInt();
}

// Look in the process table for an UNUSED proc.
// If found, initialize state required to run in the kernel,
// and return with p->lock held.
// If there are no free procs, or a memory allocation fails, return 0.
fn allocProcess() ?*Process {
    for (&processTable) |*process| {
        process.lock.acquire();
        if (process.state == .unused) {
            allocFoundProcess(process) catch return null;
            return process;
        }
        process.lock.release();
    }
    return null;
}

// free a proc structure and the data hanging from it,
// including user pages.
// p->lock must be held.
fn free(process: *Process) void {
    if (process.ownedRingbufsCount > 0) {
        ringbuf.ringbuf_disown_all(process);
    }
    if (process.allocatedTrapFrame) {
        alloc.freePage(process.trapFrame.asPagePointer()) catch @panic("could not free trapframe");
        process.allocatedTrapFrame = false;
    }

    if (process.allocatedPageTable) {
        freePageTable(process.pageTable, process.size);
        process.allocatedPageTable = false;
    }
    process.topFreeVirtualPage = ml.trapframe_virtual_address.sub(2 * ad.page_size);
    process.size = 0;
    process.ownedRingbufsCount = 0;
    process.pid = 0;
    process.parentProcess = null;
    process.nameLength = 0;
    process.sleepingOnChannel = null;
    process.isKilled = false;
    process.exitStatus = 0;
    process.state = .unused;
}

// Create a user page table for a given process, with no user memory,
// but with trampoline and trapframe pages.
fn createPagetable(process: *Process) !ad.PageTablePtr {
    // An empty page table.
    const pageTable = try mem.uvmCreate();
    errdefer mem.uvmFree(pageTable, 0);

    // map the trampoline code (for system call return)
    // at the highest user virtual address.
    // only the supervisor uses it, on the way
    // to/from user space, so not PTE_U.
    try mem.kernelVirtualMap(pageTable, ml.trampoline_virtual_address, ml.trampolinePhysicalAddress(), ad.page_size, .{ .read = true, .write = true });
    errdefer mem.uvmUnmap(pageTable, ml.trampoline_virtual_address, 1, false);

    // map the trapframe page just below the trampoline page, for
    // trampoline.S.
    try mem.kernelVirtualMap(pageTable, ml.trapframe_virtual_address, .fromPtr(process.trapFrame), ad.page_size, .{ .read = true, .write = true });
    errdefer mem.uvmUnmap(pageTable, ml.trapframe_virtual_address, 1, false);

    return pageTable;
}

// Free a process's page table, and free the
// physical memory it refers to.
fn freePageTable(pageTable: ad.PageTablePtr, size: usize) void {
    errdefer mem.uvmUnmap(pageTable, ml.trampoline_virtual_address, 1, false);
    errdefer mem.uvmUnmap(pageTable, ml.trapframe_virtual_address, 1, false);
    errdefer mem.uvmFree(pageTable, size);
}

// a user program that calls exec("/init")
// assembled from ../user/initcode.S
// od -t xC ../user/initcode
const initcode = [_]u8{ 0x17, 0x05, 0x00, 0x00, 0x13, 0x05, 0x45, 0x02, 0x97, 0x05, 0x00, 0x00, 0x93, 0x85, 0x35, 0x02, 0x93, 0x08, 0x70, 0x00, 0x73, 0x00, 0x00, 0x00, 0x93, 0x08, 0x20, 0x00, 0x73, 0x00, 0x00, 0x00, 0xef, 0xf0, 0x9f, 0xff, 0x2f, 0x69, 0x6e, 0x69, 0x74, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

// nice formatted
// const initcode = [_]u8 {
//   0x17, 0x05, 0x00, 0x00, 0x13, 0x05, 0x45, 0x02,
//   0x97, 0x05, 0x00, 0x00, 0x93, 0x85, 0x35, 0x02,
//   0x93, 0x08, 0x70, 0x00, 0x73, 0x00, 0x00, 0x00,
//   0x93, 0x08, 0x20, 0x00, 0x73, 0x00, 0x00, 0x00,
//   0xef, 0xf0, 0x9f, 0xff, 0x2f, 0x69, 0x6e, 0x69,
//   0x74, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00,
//   0x00, 0x00, 0x00, 0x00
// };

// Set up first user process.
pub fn initFirstUser() void {
    initialProcess = allocProcess() orelse @panic("could not find spot for init process");
    defer initialProcess.lock.release();

    // allocate one user page and copy initcode's instructions
    // and data into it.
    mem.uvmFirst(initialProcess.pageTable, initcode[0..]);
    initialProcess.size = ad.page_size;

    // prepare for the very first "return" from kernel to user.
    initialProcess.trapFrame.epc = 0; // user program counter
    initialProcess.trapFrame.sp = ad.page_size; // user stack pointer

    const name = "initcode";
    @memcpy(initialProcess.nameBuffer[0..name.len], name);
    initialProcess.nameLength = name.len;

    initialProcess.currentWorkingDirectory = c.namei(@constCast("/"));
    initialProcess.state = .runnable;
}

// A fork child's very first scheduling by scheduler()
// will switchContext to forkret.
fn forkReturn() void {

    // Still holding p->lock from scheduler.
    getCurrent().?.lock.release();
}
// void
// forkret(void)
// {
//   static int first = 1;
//
//   release(&myproc()->lock);
//
//   if (first) {
//     // File system initialization must be run in the context of a
//     // regular process (e.g., because it calls sleep), and thus cannot
//     // be run from main().
//     first = 0;
//     fsinit(ROOTDEV);
//   }
//
//   usertrapret();
// }
//

// Grow or shrink user memory by n bytes.
pub fn changeProccessMemSize(size_diff: i32) !void {
    const current = getCurrent() orelse return error.CouldNotGetCurrent;
    const old_size = current.size;
    if (size_diff > 0) {
        current.size = try mem.uvmAlloc(current.pageTable, old_size, old_size + size_diff, .{ .read = true, .write = true });
    } else if (size_diff < 0) {
        current.size = try mem.uvmDealloc(current.pageTable, old_size, old_size + size_diff);
    }
}

// Create a new process, copying the parent.
// Sets up child kernel stack to return as if from fork() system call.
pub fn fork() !u32 {
    const parent_process = getCurrent() orelse return error.CouldNotGetCurrent;
    var child_pid: u32 = undefined;
    var child_process: *Process = undefined;

    // set up child process
    {
        child_process = allocProcess() orelse return error.CouldNotAllocateProcess;
        defer child_process.lock.release();
        errdefer child_process.free();

        // Copy user memory from parent to child.
        try mem.uvmCopy(parent_process.pageTable, child_process.pageTable, parent_process.size);
        child_process.size = parent_process.size;

        // copy saved user registers.
        child_process.trapFrame.* = parent_process.trapFrame.*;

        // Cause fork to return 0 in the child.
        child_process.trapFrame.a0 = 0;

        // increment reference counts on open file descriptors.
        for (parent_process.openFiles, 0..) |potential_file, index| {
            if (potential_file) |open_file| {
                child_process.openFiles[index] = c.filedup(open_file);
            }
        }
        child_process.currentWorkingDirectory = c.idup(parent_process.currentWorkingDirectory);

        child_process.nameLength = parent_process.nameLength;
        child_process.nameBuffer = @memcpy(&child_process.nameBuffer, parent_process.nameBuffer[0..parent_process.nameLength]);

        child_pid = child_process.pid;
    }

    // set parent relationship
    {
        waitLock.acquire();
        defer waitLock.release();

        child_process.parentProcess = parent_process;
    }

    // indicate child ready to run
    {
        child_process.lock.acquire();
        defer child_process.lock.release();

        child_process.state = .runnable;
    }

    return child_pid;
}

// Pass p's abandoned children to init.
// Caller must hold wait_lock.
fn reparentChildren(abandonedProcess: *Process) void {
    for (processTable) |proc| {
        if (proc.parentProcess == abandonedProcess) {
            proc.parentProcess = initialProcess;
            scheduler.wakeup(initialProcess);
        }
    }
}

// Exit the current process.  Does not return.
// An exited process remains in the zombie state
// until its parent calls wait().
pub fn exit(status: u32) void {
    const current_process = getCurrent() orelse @panic("no process running");

    if (current_process == initialProcess) @panic("init exiting");

    // Close all open files.
    for (current_process.openFiles, 0..) |potential_file, index| {
        if (potential_file) |open_file| {
            c.fileclose(open_file);
            current_process.openFiles[index] = null;
        }
    }

    // put directory
    {
        c.begin_op();
        defer c.end_op();

        c.iput(current_process.currentWorkingDirectory);
    }

    {
        waitLock.acquire();
        defer waitLock.release();

        // Give any children to init.
        reparentChildren(current_process);

        // Parent might be sleeping in wait().
        scheduler.wakeup(current_process.parentProcess.?);

        current_process.lock.acquire(); // keep holding for scheduler
        current_process.exitStatus = status;
        current_process.state = .zombie;
    }

    // Jump into the scheduler, never to return.
    scheduler.switchToScheduler();
    @panic("zombie exit");
}

// Wait for a child process to exit and return its pid.
// Return -1 if this process has no children.
pub fn wait(exit_status_destination: ?ad.UserAddress) !u32 {
    const current_process = getCurrent() orelse return error.CouldNotGetCurrent;

    waitLock.acquire();
    errdefer waitLock.release();

    while (true) {
        // Scan through table looking for exited children.
        var have_kids: bool = false;
        for (processTable) |process| {
            if (process.parentProcess != current_process) continue;

            // make sure the child isn't still in exit() or switchContext().
            process.lock.acquire();
            defer process.lock.release();

            have_kids = true;
            if (process.state == .zombie) {
                // Found one.
                if (exit_status_destination) |destination| {
                    try mem.copyOut(current_process.pageTable, destination, std.mem.asBytes(&process.exitStatus));
                }
                const pid = process.pid;
                free(process);
                return pid;
            }
        }

        // No point waiting if we don't have any children.
        if (!have_kids or isKilledO(current_process)) return;

        scheduler.sleep(current_process, waitLock);
    }
}


// Kill the process with the given pid.
// The victim won't exit until it tries to return
// to user space (see usertrap() in trap.c).
pub fn kill(target_pid: u32) !void {
    for (processTable) |process| {
        process.lock.acquire();
        defer process.lock.release();

        if (process.pid == target_pid) {
            process.isKilled = true;
            if (process.state == .sleeping) {
                // Wake process from sleep().
                process.state = .runnable;
            }
            return;
        }
    }
    return error.PidNotFound;
}

pub fn setKilled(process: *Process) void {
    process.lock.acquire();
    defer process.lock.release();

    process.isKilled = true;
}

//  TODO:
pub fn isKilledO(process: *Process) bool {
    process.lock.acquire();
    defer process.lock.release();

    return process.isKilled;
}

// Copy to either a user address, or kernel address,
// depending on usr_dst.
//  TODO: remove
export fn either_copyout(isUserDestination: c_int, destination: c.uint64, source: *anyopaque, length: c.uint64) c_int {
    const process = getCurrent() orelse return -1;
    const destPointer: [*]u8 = @ptrFromInt(destination);
    const sourcePointer: [*]const u8 = @ptrCast(source);
    if (isUserDestination != 0) {
        mem.copyOut(process.pageTable, .fromInt(destination), sourcePointer[0..length]) catch return -1;
    } else {
        @memmove(destPointer, sourcePointer[0..length]);
    }
    return 0;
}

// Copy from either a user address, or kernel address,
// depending on usr_src.
// Returns 0 on success, -1 on error.
export fn either_copyin(destination: *anyopaque, isUserSource: c_int, source: c.uint64, length: c.uint64) c_int {
    const process = getCurrent() orelse return -1;
    const destPointer: [*]u8 = @ptrCast(destination);
    const sourcePointer: [*]const u8 = @ptrFromInt(source);

    if (isUserSource != 0) {
        mem.copyIn(process.pageTable, destPointer[0..length], .fromInt(source)) catch return -1;
    } else {
        @memmove(destPointer[0..length], sourcePointer);
    }
    return 0;
}
// Print a process listing to console.  For debugging.
// Runs when user types ^P on console.
// No lock to avoid wedging a stuck machine further.
pub fn processDump() void {
    print("\n", .{});
    for (processTable) |process| {
        if (process.state == .unused) continue;
        print("{d} {s} {s} \n", .{ process.pid, @tagName(process.state), process.nameBuffer[0..process.nameLength] });
    }
}
