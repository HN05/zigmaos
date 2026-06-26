const Sstatus = @import("csr.zig").Sstatus;
const Cpu = @import("cpu.zig");

// enable device interrupts
pub fn enable() void {
    Sstatus.set(.SIE);
}

// disable device interrupts
pub fn disable() void {
    Sstatus.clear(.SIE);
}

// are device interrupts enabled?
pub fn isEnabled() bool {
    return Sstatus.isSet(.SIE);
}

// push_off/pop_off are like intr_off()/intr_on() except that they are matched:
// it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
// are initially off, then push_off, pop_off leaves them off.
pub fn pushOff() void {
    const previousInterruptState = isEnabled();
    disable();

    const cpu = Cpu.getCurrent();
    if (cpu.pushDepth == 0) {
        cpu.interruptsEnabled = previousInterruptState;
    }
    cpu.pushDepth += 1;
}

pub fn popOff() void {
    if (isEnabled()) {
        @panic("pop_off - interruptible");
    }

    const cpu = Cpu.getCurrent();
    if (cpu.pushDepth < 1) {
        @panic("pop_off");
    }

    cpu.pushDepth -= 1;
    if (cpu.pushDepth == 0 and cpu.interruptsEnabled) {
        enable();
    }
}
