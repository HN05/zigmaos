const std = @import("std");
const csr = @import("csr.zig");
const riscv = @import("common").riscv;
const memlayout = @import("memlayout.zig");
const uart = @import("uart.zig");
const print = @import("klog.zig").print;
const plic = @import("plic.zig");
const ticks = @import("ticks.zig").ticks;
const ad = @import("address.zig");
const interrupts = @import("interrupts.zig");
const Cpu = @import("cpu.zig");

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/proc.h");
    @cInclude("kernel/defs.h");
});

extern const uservec: anyopaque;
extern const userret: anyopaque;

extern fn kernelvec() void;

pub fn initHart() void {
    csr.Stvec.write(@intFromPtr(&kernelvec));
}

//
// handle an interrupt, exception, or system call from user space.
// called from trampoline.S
//
export fn usertrap() void {
    if (csr.Sstatus.isSet(.SPP)) {
        @panic("usertrap: not from user mode");
    }

    // send interrupts and exceptions to kerneltrap(),
    // since we're now in the kernel.
    csr.Stvec.write(@intFromPtr(&kernelvec));

    const process: *c.struct_proc = c.myproc();
    const epc = &process.trapframe[0].epc;

    // save user program counter.
    epc.* = @intCast(csr.Sepc.read());

    const scause = csr.Scause.read();
    switch (scause.kind()) {
        .syscall => {
            if (c.killed(process) != 0) {
                c.exit(-1);
            }

            // sepc points to the ecall instruction,
            // but we want to return to the next instruction.
            epc.* += 4;

            // an interrupt will change sepc, scause, and sstatus,
            // so enable only now that we're done with those registers.
            interrupts.enable();

            c.syscall();
        },
        .interrupt => {
            handleDeviceInterrupt(scause);
        },
        .exception => {
            print("usertrap(): unexpected scause {x} pid={d}\n", .{ scause.raw(), process.pid });
            print("            sepc={x} stval={x}\n", .{ csr.Sepc.read(), csr.Stval.read() });
            c.setkilled(process);
        },
    }

    if (c.killed(process) != 0) {
        c.exit(-1);
    }

    // give up the CPU if this is a timer interrupt.
    if (scause == .supervisorSoftwareInterrupt) {
        c.yield();
    }

    usertrapret();
}

//
// return to user space
//
export fn usertrapret() void {
    const process: *c.struct_proc = c.myproc();
    const trampoline_int = memlayout.trampolinePhysicalAddress().toInt();
    const uservec_int = @intFromPtr(&uservec);
    const userret_int = @intFromPtr(&userret);

    // we're about to switch the destination of traps from
    // kerneltrap() to usertrap(), so turn off interrupts until
    // we're back in user space, where usertrap() is correct.
    interrupts.disable();

    // send syscalls, interrupts, and exceptions to uservec in trampoline.S
    const trampoline_uservec = memlayout.trampoline_virtual_address.add(uservec_int - trampoline_int);
    csr.Stvec.write(trampoline_uservec.toInt());

    // set up trapframe values that uservec will need when
    // the process next traps into the kernel.
    const trapframe: *c.struct_trapframe = process.trapframe;
    trapframe.kernel_satp = csr.Satp.readInt(); // kernel page table
    trapframe.kernel_sp = process.kstack + memlayout.kernel_stack_page_count * riscv.page_size; // process's kernel stack
    trapframe.kernel_trap = @intFromPtr(&usertrap);
    trapframe.kernel_hartid = riscv.Register.read(.tp); // hartid for cpuid()

    // set up the registers that trampoline.S's sret will use
    // to get to user space.

    // set S Previous Privilege mode to User.
    csr.Sstatus.chain()
        .clear(.SPP) // clear SPP to 0 for user mode
        .set(.SPIE) // enable interrupts in user mode
        .commit();

    // set S Exception Program Counter to the saved user pc.
    csr.Sepc.write(trapframe.epc);

    // tell trampoline.S the user page table to switch to.
    const satp = csr.Satp.make(@ptrCast(@alignCast(process.pagetable)));

    // jump to userret in trampoline.S at the top of memory, which
    // switches to the user page table, restores user registers,
    // and switches to user mode with sret.
    const trampoline_userret: *const fn (usize) callconv(.c) void = @ptrFromInt(memlayout.trampoline_virtual_int + (userret_int - trampoline_int));
    trampoline_userret(satp);
}

// interrupts and exceptions from kernel code go here via kernelvec,
// on whatever the current kernel stack is.
export fn kerneltrap() void {
    const sepc = csr.Sepc.read();
    const sstatus = csr.Sstatus.read();
    const scause = csr.Scause.read();

    if (!csr.Sstatus.isSet(.SPP)) {
        @panic("kerneltrap: not from supervisor mode");
    }
    if (interrupts.isEnabled()) {
        @panic("kerneltrap: interrupts enabled");
    }

    if (scause.isInterrupt()) {
        handleDeviceInterrupt(scause);
    } else {
        print("scause {x}\n", .{scause.raw()});
        print("sepc={x} stval={x}\n", .{ sepc, csr.Stval.read() });
        @panic("kerneltrap");
    }

    // give up the CPU if this is a timer interrupt.
    if (scause == .supervisorSoftwareInterrupt and c.myproc() != 0 and c.myproc().*.state == c.RUNNING) {
        c.yield();
    }

    // the yield() may have caused some traps to occur,
    // so restore trap registers for use by kernelvec.S's sepc instruction.
    csr.Sepc.write(sepc);
    csr.Sstatus.write(sstatus);
}

// check if it's an external interrupt or software interrupt,
// and handle it.
// returns 2 if timer interrupt,
// 1 if other device,
// 0 if not recognized.
fn handleDeviceInterrupt(scause: csr.Scause) void {
    switch (scause) {
        .supervisorExternalInterrupt => {
            // this is a supervisor external interrupt, via PLIC.

            // irq indicates which device interrupted.
            const irq = plic.claim();
            switch (irq) {
                .uart => uart.interrupt(),
                .virtio => c.virtio_disk_intr(),
                else => print("unexpected interrupt irq={d}\n", .{irq}),
            }
            // the PLIC allows each device to raise at most one
            // interrupt at a time; tell the PLIC the device is
            // now allowed to interrupt again.
            if (irq != .null) {
                plic.complete(irq);
            }
        },
        .supervisorSoftwareInterrupt => {
            // software interrupt from a machine-mode timer interrupt,
            // forwarded by timervec in kernelvec.S.
            if (Cpu.getCurrentId() == 0) {
                ticks.incrementSafe();
            }
            // acknowledge the software interrupt by clearing
            // the SSIP bit in sip.
            csr.Sip.clear(.SSIP);
        },
        else => return,
    }
}
