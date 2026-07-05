const kernel = @import("root");
const std = @import("std");
const common = @import("common");

const syscall = @import("syscall.zig");

const print = kernel.logging.print;
const execution = kernel.execution;
const csr = kernel.riscv.csr;
const plic = kernel.riscv.plic;
const cpu_ticks = execution.cpu_ticks;
const page_size = kernel.memory.pages.page_size;
const memlayout = kernel.memory.layout;
const drivers = kernel.drivers;
const conc = kernel.concurrency;
const Process = execution.Process;
const riscv = common.riscv;

extern const uservec: anyopaque;
extern const userret: anyopaque;

extern fn kernelvec() void;

fn kernelVecAddress() usize {
    return @intFromPtr(&kernelvec);
}

pub fn userRetAddress() usize {
    return @intFromPtr(&userret);
}

fn userVecAddress() usize {
    return @intFromPtr(&uservec);
}

pub fn initHart() void {
    csr.Stvec.write(kernelVecAddress());
}

//
// handle an interrupt, exception, or system call from user space.
// called from trampoline.S
//
export fn usertrap() usize {
    if (csr.Sstatus.isSet(.SPP)) {
        @panic("usertrap: not from user mode");
    }

    // send interrupts and exceptions to kerneltrap(),
    // since we're now in the kernel.
    csr.Stvec.write(kernelVecAddress());

    const process = Process.getCurrentForce();

    // save user program counter.
    process.trapFrame.epc = csr.Sepc.read();

    const scause = csr.Scause.read();
    switch (scause.kind()) {
        .syscall => {
            if (process.isKilled()) {
                Process.exit(-1);
            }

            // sepc points to the ecall instruction,
            // but we want to return to the next instruction.
            process.trapFrame.epc += 4;

            // an interrupt will change sepc, scause, and sstatus,
            // so enable only now that we're done with those registers.
            conc.interrupts.enable();

            syscall.handler();
        },
        .interrupt => {
            handleDeviceInterrupt(scause);
        },
        .exception => {
            //  TODO: do vm fault
            print("usertrap(): unexpected scause {x} pid={d}\n", .{ scause.raw(), process.pid_unsafe });
            print("            sepc={x} stval={x}\n", .{ csr.Sepc.read(), csr.Stval.read() });
            process.setKilled();
        },
    }

    if (process.isKilled()) Process.exit(-1);

    // give up the CPU if this is a timer interrupt.
    if (scause == .supervisorSoftwareInterrupt) {
        execution.scheduler.yield();
    }

    return prepareReturn();
}

//
// return to user space
//
pub fn prepareReturn() usize {
    const process = Process.getCurrentForce();

    conc.interrupts.disable();

    const trampoline_base = memlayout.trampolinePhysicalAddress();
    const uservec_offset = userVecAddress() - trampoline_base.toInt();
    const trampoline_uservec = memlayout.trampoline_virtual_address.add(uservec_offset);
    csr.Stvec.write(trampoline_uservec.toInt());

    const trapframe: *Process.TrapFrame = process.trapFrame;
    trapframe.kernel_satp = csr.Satp.readInt();
    trapframe.kernel_sp = process.kernelStackAddress.toInt() + memlayout.kernel_stack_page_count * page_size;
    trapframe.kernel_trap = @intFromPtr(&usertrap);
    trapframe.kernel_hartid = riscv.Register.read(.tp);

    csr.Sstatus.chain()
        .clear(.SPP)
        .set(.SPIE)
        .commit();

    csr.Sepc.write(trapframe.epc);

    return csr.Satp.make(process.pageTable);
}

fn isKernelText(x: usize) bool {
    return x >= 0x80000000 and x < 0x8000a000;
}

fn badKernelPc(x: usize) bool {
    return !isKernelText(x);
}

// interrupts and exceptions from kernel code go here via kernelvec,
// on whatever the current kernel stack is.
export fn kerneltrap() void {
    const sepc = csr.Sepc.read();
    const stval = csr.Stval.read();
    const stvec = csr.Stvec.read();
    const sstatus = csr.Sstatus.read();
    const scause = csr.Scause.read();

    if (!csr.Sstatus.isSet(.SPP)) {
        print("KERNELVEC GOT USER TRAP\n", .{});
        print("scause={x} sepc={x} stval={x} stvec={x} sp={x} ra={x}\n", .{
            scause.raw(),
            sepc,
            stval,
            stvec,
            riscv.Register.read(.sp),
            riscv.Register.read(.ra),
        });
        @panic("kerneltrap: not from supervisor mode");
    }
    if (badKernelPc(sepc)) {
        print("sp={x} kstack_lowest={x} trapframe={x}\n", .{
            riscv.Register.read(.sp),
            memlayout.kernelStackAddress(common.param.NPROC - 1).toInt(),
            memlayout.trapframe_virtual_address.toInt(),
        });
        print("BAD SUPERVISOR PC sepc={x} stval={x} stvec={x} sp={x} ra={x}\n", .{
            sepc,
            stval,
            stvec,
            riscv.Register.read(.sp),
            riscv.Register.read(.ra),
        });
        @panic("bad supervisor sepc on trap entry");
    }
    if (conc.interrupts.isEnabled()) {
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
    if (scause == .supervisorSoftwareInterrupt) {
        if (Process.getCurrent()) |process| {
            if (process.state_unsafe == .running) {
                execution.scheduler.yield();
            }
        }
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
                .null => return,
                .uart => drivers.uart.interrupt(),
                .virtio => drivers.disk.interrupt(),
                else => print("unexpected interrupt irq={d}\n", .{irq}),
            }
            // the PLIC allows each device to raise at most one
            // interrupt at a time; tell the PLIC the device is
            // now allowed to interrupt again.
            plic.complete(irq);
        },
        .supervisorSoftwareInterrupt => {
            //  TODO: do new modern way
            // software interrupt from a machine-mode timer interrupt,
            // forwarded by timervec in kernelvec.S.
            if (execution.Cpu.getCurrentId() == 0) {
                cpu_ticks.incrementSafe();
            }
            // acknowledge the software interrupt by clearing
            // the SSIP bit in sip.
            csr.Sip.clear(.SSIP);
        },
        else => return,
    }
}
