const Cpu = @import("cpu.zig");
const common = @import("common");
const Context = common.riscv.Context;
const interrupts = @import("../interrupts.zig");
const Process = @import("process.zig");
const SpinLock = @import("../spinlock.zig");

// from switchContext.S
extern const switchContext: fn (*Context, *Context) void;

// Per-CPU process scheduler.
// Each CPU calls scheduler() after setting itself up.
// Scheduler never returns.  It loops, doing:
//  - choose a process to run.
//  - switchContext to start running that process.
//  - eventually that process transfers control
//    via switchContext back to the scheduler.
pub fn loop() void {
    const cpu = Cpu.getCurrent();
    cpu.runningProcess = null;

    while (true) {
        // Avoid deadlock by ensuring that devices can interrupt.
        interrupts.enable();

        for (&Process.processTable) |*process| {
            process.lock.acquire();
            defer process.lock.release();

            if (process.state_unsafe == .runnable) {

                // Switch to chosen process.  It is the process's job
                // to release its lock and then reacquire it
                // before jumping back to us.
                process.state_unsafe = .running;
                cpu.runningProcess = process;
                switchContext(&cpu.context, &process.context);

                // Process is done running for now.
                // It should have changed its p->state before coming back.
                cpu.runningProcess = null;
            }
        }
    }
}

// Switch to scheduler.  Must hold only p->lock
// and have changed proc->state. Saves and restores
// intena because intena is a property of this
// kernel thread, not this CPU. It should
// be proc->intena and proc->noff, but that would
// break in the few places where a lock is held but
// there's no process.
pub fn switchToScheduler() void {
    const process = Process.getCurrent() orelse @panic("switchToScheduler: no process to switch from");
    if (!process.lock.isHolding()) @panic("switchToScheduler: not holding process lock");
    if (process.state_unsafe == .running) @panic("switchToScheduler: process is running");

    const cpu = Cpu.getCurrent();
    if (cpu.pushDepth != 1) @panic("switchToScheduler: locks");
    if (interrupts.isEnabled()) @panic("switchToScheduler: can't be interrupted");

    const previous_interrupt_state = cpu.interruptsEnabled;
    switchContext(&process.context, &cpu.context);
    cpu.interruptsEnabled = previous_interrupt_state;
}

// Give up the CPU for one scheduling round.
pub fn yield() void {
    const process = Process.getCurrent() orelse @panic("no proccess to yield");
    process.lock.acquire();
    defer process.lock.release();

    process.state_unsafe = .runnable;
    switchToScheduler();
}

// Atomically release lock and sleep on chan.
// Reacquires lock when awakened.
pub fn sleep(channel: *anyopaque, spinlock: *SpinLock) void {
    const process = Process.getCurrent() orelse @panic("no process to put  sleep");

    // Must acquire p->lock in order to
    // change p->state and then call sched.
    // Once we hold p->lock, we can be
    // guaranteed that we won't miss any wakeup
    // (wakeup locks p->lock),
    // so it's okay to release lk.
    process.lock.acquire();
    spinlock.release();

    // Reacquire original lock.
    defer spinlock.acquire();
    defer process.lock.release();

    // Go to sleep.
    process.sleeping_channel_unsafe = channel;
    process.state_unsafe = .sleeping;

    switchToScheduler();

    // Tidy up.
    process.sleeping_channel_unsafe = null;
}

// Wake up all processes sleeping on chan.
// Must be called without any p->lock.
pub fn wakeup(channel: *anyopaque) void {
    const current_process = Process.getCurrent();
    for (&Process.processTable) |*process| {
        if (current_process) |cur_proc| {
            if (cur_proc == process) continue;
        }
        process.lock.acquire();
        defer process.lock.release();

        if (process.state_unsafe == .sleeping and process.sleeping_channel_unsafe == channel) {
            process.state_unsafe = .runnable;
        }
    }
}
