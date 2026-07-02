const std = @import("std");
const common = @import("common");

const address = @import("address.zig");

const registers = common.riscv.registers;

pub fn FlagOps(comptime Flag: type) type {
    return struct {
        fn mask(flag: Flag) usize {
            return @intFromEnum(flag);
        }

        pub fn allFlagsMask() usize {
            var result: usize = 0;
            inline for (std.enums.values(Flag)) |flag| {
                result |= mask(flag);
            }
            return result;
        }

        pub fn set(flag: Flag, value: usize) usize {
            return value | mask(flag);
        }

        pub fn clear(flag: Flag, value: usize) usize {
            return value & ~mask(flag);
        }

        pub fn isSet(flag: Flag, value: usize) bool {
            return (value & mask(flag)) != 0;
        }
    };
}

pub fn CsrWithFlags(comptime name: []const u8, comptime Flag: type) type {
    return struct {
        const Self = @This();
        pub const registerName = name;
        pub const flags = FlagOps(Flag);
        pub const Chain = struct {
            value: usize,

            pub fn set(self: Chain, flag: Flag) Chain {
                return .{ .value = flags.set(flag, self.value) };
            }

            pub fn clear(self: Chain, flag: Flag) Chain {
                return .{ .value = flags.clear(flag, self.value) };
            }

            pub fn setAll(self: Chain) Chain {
                return .{ .value = self.value | flags.allFlagsMask() };
            }

            pub fn clearAll(self: Chain) Chain {
                return .{ .value = self.value & ~flags.allFlagsMask() };
            }

            pub fn commit(self: Chain) void {
                Self.write(self.value);
            }

            pub fn valueOf(self: Chain) usize {
                return self.value;
            }
        };

        pub inline fn read() usize {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> usize),
            );
        }

        pub inline fn write(value: usize) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }

        pub fn chain() Chain {
            return .{ .value = read() };
        }

        pub fn set(flag: Flag) void {
            chain().set(flag).commit();
        }

        pub fn clear(flag: Flag) void {
            chain().clear(flag).commit();
        }

        pub fn setAllFlags() void {
            chain().setAll().commit();
        }

        pub fn clearAllFlags() void {
            chain().clearAll().commit();
        }

        pub fn isSet(flag: Flag) bool {
            return flags.isSet(flag, read());
        }
    };
}

pub fn Csr(comptime name: []const u8) type {
    return struct {
        pub const registerName = name;
        pub inline fn read() usize {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> usize),
            );
        }

        pub inline fn write(value: usize) void {
            asm volatile ("csrw " ++ name ++ ", a0"
                :
                : [value] "{a0}" (value),
            );
        }
    };
}

pub fn CsrReadOnly(comptime name: []const u8) type {
    return struct {
        pub const registerName = name;
        pub inline fn read() usize {
            return asm volatile ("csrr a0, " ++ name
                : [ret] "={a0}" (-> usize),
            );
        }
    };
}

// Supervisor Trap Cause
pub const Scause = enum(usize) {
    pub const TrapKind = enum {
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
        if (self == .environmentCallFromUMode) return .syscall;
        if (self.isInterrupt()) return .interrupt;
        return .exception;
    }

    pub inline fn readRaw() usize {
        return asm volatile ("csrr a0, scause"
            : [ret] "={a0}" (-> usize),
        );
    }

    pub fn read() Scause {
        return @enumFromInt(readRaw());
    }
};

pub const MstatusFlags = enum(usize) {
    Machine_interrupts_enable = 1 << 3,
};

pub const BaseMstatus = CsrWithFlags("mstatus", MstatusFlags);

pub const Mstatus = struct {
    pub const flags = BaseMstatus.flags;
    pub const Machine_prev_mask: usize = 3 << 11;
    pub const Mpp = enum(usize) {
        Machine = 3 << 11,
        Supervisor = 1 << 11,
        User = 0 << 11,
    };

    pub fn read() usize {
        return BaseMstatus.read();
    }

    pub fn write(value: usize) void {
        BaseMstatus.write(value);
    }

    pub fn set(flag: MstatusFlags) void {
        BaseMstatus.set(flag);
    }

    pub fn clear(flag: MstatusFlags) void {
        BaseMstatus.clear(flag);
    }

    pub fn isSet(flag: MstatusFlags) bool {
        return BaseMstatus.isSet(flag);
    }

    pub fn setMpp(mode: Mpp) void {
        const value = (read() & ~Machine_prev_mask) | @intFromEnum(mode);
        write(value);
    }
};

pub const SstatusFlags = enum(usize) {
    SPP = 1 << 8, // Previous mode, 1=Supervisor, 0=User
    SPIE = 1 << 5, // Supervisor Previous Interrupt Enable
    UPIE = 1 << 4, // User Previous Interrupt Enable
    SIE = 1 << 1, // Supervisor Interrupt Enable
    UIE = 1 << 0, // User Interrupt Enable
};

pub const Sstatus = CsrWithFlags("sstatus", SstatusFlags);

pub const SipFlags = enum(usize) {
    SSIP = 1 << 1, // supervisor software interrupt pending
    STIP = 1 << 5, // supervisor timer interrupt pending
    SEIP = 1 << 9, // supervisor external interrupt pending
};

pub const Sip = CsrWithFlags("sip", SipFlags);

// Supervisor Interrupt Enable
pub const SieFlags = enum(usize) {
    SEIE = 1 << 9, // external
    STIE = 1 << 5, // timer
    SSIE = 1 << 1, // software
};

pub const Sie = CsrWithFlags("sie", SieFlags);

// Machine-mode Interrupt Enable
pub const MieFlags = enum(usize) {
    MEIE = 1 << 11, // external
    MTIE = 1 << 7, // timer
    MSIE = 1 << 3, // software
};

pub const Mie = CsrWithFlags("mie", MieFlags);

// Machine Exception Delegation
pub const MedelegFlags = enum(usize) {
    instructionAddressMisaligned = 1 << 0,
    instructionAccessFault = 1 << 1,
    illegalInstruction = 1 << 2,
    breakpoint = 1 << 3,
    loadAddressMisaligned = 1 << 4,
    loadAccessFault = 1 << 5,
    storeAddressMisaligned = 1 << 6,
    storeAccessFault = 1 << 7,
    environmentCallFromUMode = 1 << 8,
    environmentCallFromSMode = 1 << 9,
    environmentCallFromMMode = 1 << 11,
    instructionPageFault = 1 << 12,
    loadPageFault = 1 << 13,
    storePageFault = 1 << 15,
};
pub const Medeleg = CsrWithFlags("medeleg", MedelegFlags);

// Machine Interrupt Delegation
pub const MidelegFlags = enum(usize) {
    supervisorSoftwareInterrupt = 1 << 1,
    supervisorTimerInterrupt = 1 << 5,
    supervisorExternalInterrupt = 1 << 9,
};
pub const Mideleg = CsrWithFlags("mideleg", MidelegFlags);

// supervisor exception program counter, holds the
// instruction address to which a return from
// exception will go.
pub const Sepc = Csr("sepc");

pub const Mepc = Csr("mepc");

// Supervisor Trap-Vector Base Address
// low two bits are mode.
pub const Stvec = Csr("stvec");

// Machine-mode interrupt vector
pub const Mtvec = Csr("mtvec");

// Physical Memory Protection
pub const PmpcfgFlags = enum(usize) {
    read = 1 << 0, // read
    write = 1 << 1, // write
    execute = 1 << 2, // execute
    NAPOT = 3 << 3, // naturally aligned power-of-two region
    lock = 1 << 7, // lock
};
pub const Pmpcfg0 = CsrWithFlags("pmpcfg0", PmpcfgFlags);

pub const Pmpaddr0 = struct {
    const base = Csr("pmpaddr0");

    pub const allPhysicalMemory: usize = 0x3fffffffffffff;

    pub fn write(value: usize) void {
        base.write(value);
    }

    pub fn read() usize {
        return base.read();
    }

    pub fn allowAllPhysicalMemory() void {
        write(allPhysicalMemory);
    }
};

// supervisor address translation and protection;
// holds the address of the page table.
pub const Satp = struct {
    const base = Csr("satp");

    // use riscv's sv39 page table scheme.
    pub const SATP_SV39 = @as(usize, 8) << 60;

    pub fn make(pagetable: address.PageTablePtr) usize {
        const ppn = @intFromPtr(pagetable) >> 12;
        return SATP_SV39 | ppn;
    }

    pub fn write(pagetable: address.PageTablePtr) void {
        base.write(make(pagetable));
    }

    pub fn read() address.PageTablePtr {
        const value = base.read();
        const ppn = value & ((@as(usize, 1) << 44) - 1);
        return @ptrFromInt(ppn << 12);
    }

    pub fn readInt() usize {
        return base.read();
    }
    pub fn writeInt(value: usize) void {
        return base.write(value);
    }
};

pub const Mscratch = Csr("mscratch");

// Machine-mode Counter-Enable
pub const Mcounteren = Csr("mcounteren");

// Supervisor Trap Value
pub const Stval = CsrReadOnly("stval");

// machine-mode cycle counter
pub const Time = CsrReadOnly("time");

pub const Mhartid = CsrReadOnly("mhartid");
