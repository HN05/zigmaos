const std = @import("std");
const log_root = @import("klog.zig");
const riscv = @import("common").riscv;
const Kalloc = @import("kalloc.zig");
const plic = @import("plic.zig");
const console = @import("console.zig");
const trap = @import("trap.zig");
const memory = @import("memory.zig");
const drivers = @import("drivers.zig");
const Buffer = @import("buffer.zig");
const execution = @import("execution.zig");

const log = std.log.scoped(.kmain);

var started = std.atomic.Value(bool).init(false);

pub fn kmain() void {
    if (execution.Cpu.getCurrentId() == 0) {
        console.init();
        log.info("xv6 kernel is booting", .{});
        Kalloc.kinit(); // set up allocator (zig)
        memory.kernelMemoryInit(); // create kernel page table
        memory.kernelMemoryHartInit(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.init(); // set up interrupt controller
        plic.initHart(); // ask PLIC for device interrupts
        Buffer.cache.init_array(); // buffer cache
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
