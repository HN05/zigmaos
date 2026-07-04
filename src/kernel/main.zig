const kernel = @import("root");
const std = @import("std");
const common = @import("common");

const log_root = @import("klog.zig");
const plic = @import("plic.zig");

const execution = kernel.execution;
const traps = kernel.traps;
const mem = kernel.memory;
const drivers = kernel.drivers;
const fs = kernel.filesystem;
const log = std.log.scoped(.kmain);
const riscv = common.riscv;

var started = std.atomic.Value(bool).init(false);

pub fn kernelMain() void {
    if (execution.Cpu.getCurrentId() == 0) {
        drivers.console.init();
        log.info("xv6 kernel is booting", .{});
        mem.allocation.init(); // set up allocator (zig)
        mem.kernel.initPageTable(); // create kernel page table
        mem.kernel.enablePaging(); // turn on paging
        traps.initHart(); // install kernel trap vector
        plic.init(); // set up interrupt controller
        plic.initHart(); // ask PLIC for device interrupts
        fs.initBufferCache(); // buffer cache
        drivers.disk.init(); // emulated hard disk
        execution.Process.initFirstUser(); // first user process
        started.store(true, .seq_cst);
    } else {
        while (!started.load(.seq_cst)) {}

        log.info("hart {d} starting", .{execution.Cpu.getCurrentId()});
        mem.kernel.enablePaging(); // turn on paging
        traps.initHart(); // install kernel trap vector
        plic.initHart(); // ask PLIC for device interrupts
    }
    execution.scheduler.loop();
}

// overrides the root page allocator
pub const os = struct {
    heap: struct {
        page_allocator: std.mem.Allocator = mem.allocation.page_allocator,
    },
};
