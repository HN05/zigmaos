const kernel = @import("root");
const common = @import("common");
const std = @import("std");

const ringbuf = kernel.datastructures.ringbuf;
const print = kernel.logging.print;
const scheduler = @import("scheduler.zig");
const Cpu = @import("cpu.zig");

const mem = kernel.memory;
const ad = mem.address;
const ml = mem.layout;
const traps = kernel.traps;
const allocation = mem.allocation;
const page_size = mem.pages.page_size;
const param = common.param;
const Context = common.riscv.Context;
const Mutex = kernel.concurrency.Mutex;
const interrupts = kernel.concurrency.interrupts;
const fs = kernel.filesystem;
const Inode = fs.Inode;
const File = fs.File;

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
pub var waitLock: Mutex = .init(.spin, "wait_lock");

// Allocate a page for each process's kernel stack.
// Map it high in memory, followed by an invalid
// guard page.
pub fn mapKernelStacks(map_func: *const fn (ad.UserAddress, ad.KernelAddress, usize, mem.pages.MappingKind) void) void {
    inline for (0..processTable.len) |index| {
        const virtualAddress = ml.KSTACK(index);

        inline for (0..ml.kernel_stack_page_count) |i| {
            const virtual_page_address = virtualAddress.add(i * mem.pages.page_size);

            const physical_page = allocation.allocPage(.garbage) orelse @panic("could not get mem to map stacks");
            map_func(virtual_page_address, .fromPtr(physical_page), mem.pages.page_size, .data);
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

    pub fn asPagePointer(self: *TrapFrame) mem.pages.PagePointer {
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
lock: Mutex = .init(.spin, "process lock"),

// p->lock must be held when using these:
state_unsafe: ProcessState = .unused,
sleeping_channel_unsafe: ?*anyopaque = null, // If non-null, sleeping on channel
is_killed_unsafe: bool = false,
exit_status_unsafe: i32 = 0, // Exit status to be returned to parent's wait
pid_unsafe: u32 = 0, // process id

// wait_lock must be held when using this:
parentProcess: ?*Process = null, // null for root process

// these are private to the process, so p->lock need not be held.
kernelStackAddress: ad.UserAddress, // Virtual address of kernel stack
size: usize = 0, // Size of process memory (bytes)
pageTable: mem.pages.PageTablePtr = undefined, // User page table
topFreeVirtualPage: ad.UserAddress = ml.trapframe_virtual_address.sub(2 * page_size), // The highest free user virtual mem page. Starts at TRAPFRAME - 2*PGSIZE and goes down as pages are used.
trapFrame: *TrapFrame = undefined, // data page for trampoline.S
context: Context = undefined, // switchContext() here to run process
openFiles: [param.NOFILE]?*File = [_]?*File{null} ** param.NOFILE, // Open files
currentWorkingDirectory: *Inode = undefined,
nameBuffer: [15]u8 = undefined, // for debugging
nameLength: u4 = 0,
ownedRingbufsCount: usize = 0, // Count of ringbufs owned by this process
allocatedTrapFrame: bool = false,
allocatedPageTable: bool = false,

pub fn nameSlice(process: *const Process) []const u8 {
    return process.nameBuffer[0..process.nameLength];
}

pub fn getCurrentForce() *Process {
    return getCurrent() orelse @panic("getCurrentForce: no process running");
}

pub fn getCurrentThrows() !*Process {
    return getCurrent() orelse return error.NoProcessRunning;
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

fn init(process: *Process) !void {
    errdefer process.free();
    errdefer process.lock.release();

    process.pid_unsafe = allocProcessId();
    process.state_unsafe = .used;

    // Allocate a trapframe page.
    const trap_page = allocation.allocPage(.garbage) orelse return error.FailedMemAllocate;
    process.trapFrame = @ptrCast(trap_page);
    process.allocatedTrapFrame = true;

    // An empty user page table.
    process.pageTable = try mem.user.createPagetable(.fromPtr(process.trapFrame));
    process.allocatedPageTable = true;

    // Set up new context to start executing at forkret,
    // which returns to user space.
    const sp = process.kernelStackAddress.add(ml.kernel_stack_page_count * page_size);
    process.context = .{
        .ra = @intFromPtr(&forkReturn),
        .sp = sp.toInt(),
    };
}

// Look in the process table for an UNUSED proc.
// If found, initialize state required to run in the kernel,
// and return with p->lock held.
// If there are no free procs, or a memory allocation fails, return 0.
fn alloc() ?*Process {
    for (&processTable) |*process| {
        process.lock.acquire();
        if (process.state_unsafe == .unused) {
            process.init() catch return null;
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
        allocation.freePage(process.trapFrame.asPagePointer()) catch @panic("could not free trapframe");
        process.allocatedTrapFrame = false;
    }

    if (process.allocatedPageTable) {
        mem.user.freePageTable(process.pageTable, process.size);
        process.allocatedPageTable = false;
    }
    process.topFreeVirtualPage = ml.trapframe_virtual_address.sub(2 * page_size);
    process.size = 0;
    process.ownedRingbufsCount = 0;
    process.pid_unsafe = 0;
    process.parentProcess = null;
    process.nameLength = 0;
    process.sleeping_channel_unsafe = null;
    process.is_killed_unsafe = false;
    process.exit_status_unsafe = 0;
    process.state_unsafe = .unused;
}

// a user program that calls exec("/init")
// assembled from initcode.S
const initcode = @embedFile("initcode");

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
    initialProcess = alloc() orelse @panic("could not find spot for init process");
    defer initialProcess.lock.release();

    // allocate one user page and copy initcode's instructions
    // and data into it.
    mem.user.loadFirstProcess(initialProcess.pageTable, initcode[0..]);
    initialProcess.size = page_size;

    // prepare for the very first "return" from kernel to user.
    initialProcess.trapFrame.epc = 0; // user program counter
    initialProcess.trapFrame.sp = page_size; // user stack pointer

    const name = "initcode";
    @memcpy(initialProcess.nameBuffer[0..name.len], name);
    initialProcess.nameLength = name.len;

    initialProcess.currentWorkingDirectory = Inode.resolvePath("/").?;
    initialProcess.state_unsafe = .runnable;
}

var first_fork = std.atomic.Value(bool).init(true);
// A fork child's very first scheduling by scheduler()
// will switchContext to forkret.
fn forkReturn() void {

    // Still holding p->lock from scheduler.
    getCurrentForce().lock.release();

    // File system initialization must be run in the context of a
    // regular process (e.g., because it calls sleep), and thus cannot
    // be run from main().
    if (first_fork.cmpxchgStrong(true, false, .seq_cst, .seq_cst) == null) {
        fs.initFileSystem(.root_fs_device);
    }

    //  TODO: move this
    const satp = traps.prepareReturn();
    const trampoline = mem.layout.trampolinePhysicalAddress();
    const userret_offset = traps.userRetAddress() - trampoline.toInt();

    const trampoline_userret: *const fn (usize) callconv(.c) noreturn =
        @ptrFromInt(ml.trampoline_virtual_int + userret_offset);

    trampoline_userret(satp);
}

// Grow or shrink user memory by n bytes.
pub fn changeProcessSize(size_diff: i64) !void {
    const current = getCurrent() orelse return error.CouldNotGetCurrent;
    const old_size = current.size;
    const abs_size_diff: usize = @abs(size_diff);
    if (size_diff > 0) {
        current.size = try mem.user.alloc(current.pageTable, old_size, old_size + abs_size_diff, .{ .read = true, .write = true });
    } else if (size_diff < 0) {
        current.size = mem.user.dealloc(current.pageTable, old_size, old_size - abs_size_diff);
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
        child_process = alloc() orelse return error.CouldNotAllocateProcess;
        defer child_process.lock.release();
        errdefer child_process.free();

        // Copy user memory from parent to child.
        try mem.user.copyPageTable(parent_process.pageTable, child_process.pageTable, parent_process.size);
        child_process.size = parent_process.size;

        // copy saved user registers.
        child_process.trapFrame.* = parent_process.trapFrame.*;

        // Cause fork to return 0 in the child.
        child_process.trapFrame.a0 = 0;

        // increment reference counts on open file descriptors.
        for (parent_process.openFiles, 0..) |potential_file, index| {
            if (potential_file) |open_file| {
                child_process.openFiles[index] = open_file.duplicate();
            }
        }
        child_process.currentWorkingDirectory = parent_process.currentWorkingDirectory.duplicate();

        child_process.nameLength = parent_process.nameLength;
        @memcpy(&child_process.nameBuffer, parent_process.nameSlice());

        child_pid = child_process.pid_unsafe;
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

        child_process.state_unsafe = .runnable;
    }

    return child_pid;
}

// Pass p's abandoned children to init.
// Caller must hold wait_lock.
fn reparentChildren(abandonedProcess: *Process) void {
    for (&processTable) |*proc| {
        if (proc.parentProcess == abandonedProcess) {
            proc.parentProcess = initialProcess;
            scheduler.wakeup(initialProcess);
        }
    }
}

// Exit the current process.  Does not return.
// An exited process remains in the zombie state
// until its parent calls wait().
pub fn exit(status: i32) void {
    const current_process = getCurrent() orelse @panic("no process running");

    if (current_process == initialProcess) @panic("init exiting");

    // Close all open files.
    for (current_process.openFiles, 0..) |potential_file, index| {
        if (potential_file) |open_file| {
            open_file.close();
            current_process.openFiles[index] = null;
        }
    }

    // put directory
    {
        fs.beginOperation();
        defer fs.endOperation();

        current_process.currentWorkingDirectory.put();
    }

    {
        waitLock.acquire();
        defer waitLock.release();

        // Give any children to init.
        current_process.reparentChildren();

        // Parent might be sleeping in wait().
        scheduler.wakeup(current_process.parentProcess.?);

        current_process.lock.acquire(); // keep holding for scheduler
        current_process.exit_status_unsafe = status;
        current_process.state_unsafe = .zombie;
    }

    // Jump into the scheduler, never to return.
    scheduler.switchToScheduler();
    @panic("zombie exit");
}

// Wait for a child process to exit and return its pid.
pub fn wait(exit_status_destination: ?ad.UserAddress) !u32 {
    const current_process = getCurrent() orelse return error.CouldNotGetCurrent;

    waitLock.acquire();
    defer waitLock.release();

    while (true) {
        // Scan through table looking for exited children.
        var have_kids: bool = false;
        for (&processTable) |*process| {
            if (process.parentProcess != current_process) continue;

            // make sure the child isn't still in exit() or switchContext().
            process.lock.acquire();
            defer process.lock.release();

            have_kids = true;
            if (process.state_unsafe == .zombie) {
                // Found one.
                if (exit_status_destination) |destination| {
                    try mem.boundry.copyOut(current_process.pageTable, destination, std.mem.asBytes(&process.exit_status_unsafe));
                }
                const pid = process.pid_unsafe;
                process.free();
                return pid;
            }
        }

        // No point waiting if we don't have any children.
        if (!have_kids) return error.DoesNotHaveChildren;
        if (current_process.isKilled()) return error.ProcessIsKilled;

        scheduler.sleepWithLock(&waitLock, current_process);
    }
}

// Kill the process with the given pid.
// The victim won't exit until it tries to return
// to user space (see usertrap() in trap.c).
pub fn kill(target_pid: u32) !void {
    for (&processTable) |*process| {
        process.lock.acquire();
        defer process.lock.release();

        if (process.pid_unsafe == target_pid) {
            process.is_killed_unsafe = true;
            if (process.state_unsafe == .sleeping) {
                // Wake process from sleep().
                process.state_unsafe = .runnable;
            }
            return;
        }
    }
    return error.PidNotFound;
}

pub fn setKilled(process: *Process) void {
    process.lock.acquire();
    defer process.lock.release();

    process.is_killed_unsafe = true;
}

pub fn isKilled(process: *Process) bool {
    process.lock.acquire();
    defer process.lock.release();

    return process.is_killed_unsafe;
}

// Print a process listing to console.  For debugging.
// Runs when user types ^P on console.
// No lock to avoid wedging a stuck machine further.
pub fn dump() void {
    print("\n", .{});
    for (&processTable) |*process| {
        if (process.state_unsafe == .unused) continue;
        print("{d} {s} {s} \n", .{ process.pid_unsafe, @tagName(process.state_unsafe), process.nameSlice() });
    }
}
