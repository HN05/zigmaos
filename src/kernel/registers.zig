const std = @import("std");
const PageTable = @import("pagetable.zig").PageTable;

// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig

pub inline fn r_mhartid() usize {
    return asm volatile ("csrr a0, mhartid"
        : [ret] "={a0}" (-> usize),
    );
}

pub const MSTATUS_MPP_MASK = 3 << 11;

pub const MSTATUS = enum(usize) {
    MPP_M = 3 << 11,
    MPP_S = 1 << 11,
    MPP_U = 0 << 11,
    MIE = 1 << 3, // machine-mode interrupt enable.
};

pub inline fn r_mstatus() usize {
    return asm volatile ("csrr a0, mstatus"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_mstatus(status: usize) void {
    asm volatile ("csrw mstatus, a0"
        :
        : [status] "{a0}" (status),
    );
}

pub inline fn w_mepc(counter: usize) void {
    asm volatile ("csrw mepc, a0"
        :
        : [counter] "{a0}" (counter),
    );
}

pub const SSTATUS = enum(usize) {
    SPP = 1 << 8, // Previous mode, 1=Supervisor, 0=User
    SPIE = 1 << 5, // Supervisor Previous Interrupt Enable
    UPIE = 1 << 4, // User Previous Interrupt Enable
    SIE = 1 << 1, // Supervisor Interrupt Enable
    UIE = 1 << 0, // User Interrupt Enable


    pub fn enable(self: SSTATUS, value: usize) usize {
        return value | @intFromEnum(self);
    }

    pub fn disable(self: SSTATUS, value: usize) usize {
        return value & ~@intFromEnum(self);
    }

    pub fn isEnabled(self: SSTATUS, value: usize) bool { 
        return (value & @intFromEnum(self)) != 0;
    }
};

pub inline fn r_sstatus() usize {
    return asm volatile ("csrr a0, sstatus"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_sstatus(sstatus: usize) void {
    asm volatile ("csrw sstatus, a0"
        :
        : [sstatus] "{a0}" (sstatus),
    );
}

// Supervisor Interrupt Pending
pub const SIP = enum(usize) {
    SSIP = 1 << 1, // supervisor software interrupt pending
    STIP = 1 << 5, // supervisor timer interrupt pending
    SEIP = 1 << 9, // supervisor external interrupt pending

    pub fn enable(self: SIP, value: usize) usize {
        return value | @intFromEnum(self);
    }

    pub fn disable(self: SIP, value: usize) usize {
        return value & ~@intFromEnum(self);
    }

    pub fn isEnabled(self: SIP, value: usize) bool { 
        return (value & @intFromEnum(self)) != 0;
    }
};

pub inline fn r_sip() usize {
    return asm volatile ("csrr a0, sip"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_sip(sip: usize) void {
    asm volatile ("csrw sip, a0"
        :
        : [sip] "{a0}" (sip),
    );
}

// Supervisor Interrupt Enable
pub const SIE = enum(usize) {
    SEIE = 1 << 9, // external
    STIE = 1 << 5, // timer
    SSIE = 1 << 1, // software
};

pub inline fn r_sie() usize {
    return asm volatile ("csrr a0, sie"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_sie(sie: usize) void {
    asm volatile ("csrw sie, a0"
        :
        : [sie] "{a0}" (sie),
    );
}

// Machine-mode Interrupt Enable
pub const MIE = enum(usize) {
    MEIE = 1 << 11, // external
    MTIE = 1 << 7, // timer
    MSIE = 1 << 3, // software
};

pub inline fn r_mie() usize {
    return asm volatile ("csrr a0, mie"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_mie(mie: usize) void {
    asm volatile ("csrw mie, a0"
        :
        : [mie] "{a0}" (mie),
    );
}

// supervisor exception program counter, holds the
// instruction address to which a return from
// exception will go.
pub inline fn w_sepc(sepc: usize) void {
    asm volatile ("csrw sepc, a0"
        :
        : [sepc] "{a0}" (sepc),
    );
}

pub inline fn r_sepc() usize {
    return asm volatile ("csrr a0, sepc"
        : [ret] "={a0}" (-> usize),
    );
}

// Machine Exception Delegation
pub inline fn r_medeleg() usize {
    return asm volatile ("csrr a0, medeleg"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_medeleg(medeleg: usize) void {
    asm volatile ("csrw medeleg, a0"
        :
        : [medeleg] "{a0}" (medeleg),
    );
}

// Machine Interrupt Delegation
pub inline fn r_mideleg() usize {
    return asm volatile ("csrr a0, mideleg"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_mideleg(mideleg: usize) void {
    asm volatile ("csrw mideleg, a0"
        :
        : [mideleg] "{a0}" (mideleg),
    );
}

// Supervisor Trap-Vector Base Address
// low two bits are mode.
pub inline fn w_stvec(stvec: usize) void {
    asm volatile ("csrw stvec, a0"
        :
        : [stvec] "{a0}" (stvec),
    );
}

pub inline fn r_stvec() usize {
    return asm volatile ("csrr a0, stvec"
        : [ret] "={a0}" (-> usize),
    );
}

// Machine-mode interrupt vector
pub inline fn w_mtvec(mtvec: usize) void {
    asm volatile ("csrw mtvec, a0"
        :
        : [mtvec] "{a0}" (mtvec),
    );
}

// Physical Memory Protection
pub inline fn w_pmpcfg0(pmpcfg0: usize) void {
    asm volatile ("csrw pmpcfg0, a0"
        :
        : [pmpcfg0] "{a0}" (pmpcfg0),
    );
}

pub inline fn w_pmpaddr0(pmpaddr0: usize) void {
    asm volatile ("csrw pmpaddr0, a0"
        :
        : [pmpaddr0] "{a0}" (pmpaddr0),
    );
}

// use riscv's sv39 page table scheme.
pub const SATP_SV39 = @as(usize, 8) << 60;

pub fn MAKE_SATP(pagetable: PageTable) usize {
    return SATP_SV39 | (@intFromPtr(pagetable) >> 12);
}

// supervisor address translation and protection;
// holds the address of the page table.
pub inline fn w_satp(satp: usize) void {
    asm volatile ("csrw satp, a0"
        :
        : [satp] "{a0}" (satp),
    );
}

pub inline fn r_satp() usize {
    return asm volatile ("csrr a0, satp"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn w_mscratch(mscratch: usize) void {
    asm volatile ("csrw mscratch, a0"
        :
        : [mscratch] "{a0}" (mscratch),
    );
}

pub inline fn r_mscratch() usize {
    return asm volatile ("csrw a0, mscratch"
        : [ret] "={a0}" (-> usize),
    );
}

pub const Scause = enum(usize) {
    const TrapKind = enum {
        syscall,
        interrupt,
        exception,
    };
    // Interrupt bit clear: synchronous exceptions
    instructionAddressMisaligned = 0,
    instructionAccessFault = 1,
    illegalInstruction = 2,
    breakpoint = 3,
    loadAddressMisaligned = 4,
    loadAccessFault = 5,
    storeAddressMisaligned = 6,
    storeAccessFault = 7,

    environmentCallFromUMode = 8,
    environmentCallFromSMode = 9,
    environmentCallFromVMode = 10,
    environmentCallFromMMode = 11,

    instructionPageFault = 12,
    loadPageFault = 13,
    storePageFault = 15,

    instructionGuestPageFault = 20,
    loadGuestPageFault = 21,
    virtualInstruction = 22,
    storeGuestPageFault = 23,

    softwareCheck = 24,
    hardwareError = 25,

    // Interrupt bit set
    userSoftwareInterrupt = interruptBit | 0,
    supervisorSoftwareInterrupt = interruptBit | 1,
    virtualSupervisorSoftwareInterrupt = interruptBit | 2,
    machineSoftwareInterrupt = interruptBit | 3,

    userTimerInterrupt = interruptBit | 4,
    supervisorTimerInterrupt = interruptBit | 5,
    virtualSupervisorTimerInterrupt = interruptBit | 6,
    machineTimerInterrupt = interruptBit | 7,

    userExternalInterrupt = interruptBit | 8,
    supervisorExternalInterrupt = interruptBit | 9,
    virtualSupervisorExternalInterrupt = interruptBit | 10,
    machineExternalInterrupt = interruptBit | 11,

    supervisorGuestExternalInterrupt = interruptBit | 12,
    localCounterOverflowInterrupt = interruptBit | 13,

    // Allows storing platform/custom/unknown scause values too.
    _,

    const interruptBit: usize = 1 << (@bitSizeOf(usize) - 1);

    pub fn raw(self: Scause) usize {
        return @intFromEnum(self);
    }

    pub fn isInterrupt(self: Scause) bool {
        return (self.raw() & interruptBit) != 0;
    }

    pub fn code(self: Scause) usize {
        return self.raw() & ~interruptBit;
    }

    pub fn kind(self: Scause) TrapKind {
        return switch (self) {
            .environmentCallFromUMode => .syscall,

            .userSoftwareInterrupt,
            .supervisorSoftwareInterrupt,
            .virtualSupervisorSoftwareInterrupt,
            .machineSoftwareInterrupt,
            .userTimerInterrupt,
            .supervisorTimerInterrupt,
            .virtualSupervisorTimerInterrupt,
            .machineTimerInterrupt,
            .userExternalInterrupt,
            .supervisorExternalInterrupt,
            .virtualSupervisorExternalInterrupt,
            .machineExternalInterrupt,
            .supervisorGuestExternalInterrupt,
            .localCounterOverflowInterrupt,
            => .interrupt,

            else => .exception,
        };
    }
};

// Supervisor Trap Cause
inline fn readScauseRaw() usize {
    return asm volatile ("csrr a0, scause"
        : [ret] "={a0}" (-> usize),
    );
}

pub inline fn readScause() Scause {
    return @enumFromInt(readScauseRaw());
}

// Supervisor Trap Value
pub inline fn r_stval() usize {
    return asm volatile ("csrr a0, stval"
        : [ret] "={a0}" (-> usize),
    );
}

// Machine-mode Counter-Enable
pub inline fn w_mcounteren(mcounteren: usize) void {
    asm volatile ("csrw mcounteren, a0"
        :
        : [mcounteren] "{a0}" (mcounteren),
    );
}

pub inline fn r_mcounteren() usize {
    return asm volatile ("csrr a0, mcounteren"
        : [ret] "={a0}" (-> usize),
    );
}

// machine-mode cycle counter
pub inline fn r_time() usize {
    return asm volatile ("csrr a0, time"
        : [ret] "={a0}" (-> usize),
    );
}

// enable device interrupts
pub inline fn intr_on() void {
    w_sstatus(r_sstatus() | @intFromEnum(SSTATUS.SIE));
}

// disable device interrupts
pub inline fn intr_off() void {
    w_sstatus(r_sstatus() & ~@intFromEnum(SSTATUS.SIE));
}

// are device interrupts enabled?
pub inline fn intr_get() bool {
    return (r_sstatus() & @intFromEnum(SSTATUS.SIE)) != 0;
}

