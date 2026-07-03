const kernel = @import("root");
const std = @import("std");
const common = @import("common");

const log_root = @import("klog.zig");
const Kalloc = @import("kalloc.zig");
const plic = @import("plic.zig");
const trap = @import("trap.zig");
const memory = @import("memory.zig");

const execution = kernel.execution;
const drivers = kernel.drivers;
const fs = kernel.filesystem;
const log = std.log.scoped(.kmain);
const riscv = common.riscv;

var started = std.atomic.Value(bool).init(false);

pub fn kernelMain() void {
    if (execution.Cpu.getCurrentId() == 0) {
        drivers.console.init();
        log.info("xv6 kernel is booting", .{});
        Kalloc.kinit(); // set up allocator (zig)
        memory.kernelMemoryInit(); // create kernel page table
        memory.kernelMemoryHartInit(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.init(); // set up interrupt controller
        plic.initHart(); // ask PLIC for device interrupts
        fs.initBufferCache(); // buffer cache
        drivers.disk.init(); // emulated hard disk
        execution.Process.initFirstUser(); // first user process
        started.store(true, .seq_cst);
    } else {
        while (!started.load(.seq_cst)) {}

        log.info("hart {d} starting", .{execution.Cpu.getCurrentId()});
        memory.kernelMemoryHartInit(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.initHart(); // ask PLIC for device interrupts
    }
    execution.scheduler.loop();
}

// overrides the root page allocator
pub const os = struct {
    heap: struct {
        page_allocator: std.mem.Allocator = Kalloc.page_allocator,
    },
};
