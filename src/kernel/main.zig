const std = @import("std");
const log_root = @import("klog.zig");
const riscv = @import("common").riscv;
const Kalloc = @import("kalloc.zig");
const plic = @import("plic.zig");
const console = @import("console.zig");
const trap = @import("trap.zig");
const memory = @import("memory.zig");
const Process = @import("process.zig");
const Cpu = @import("cpu.zig");
const scheduler = @import("scheduler.zig");
const virtio = @import("virtiodriver.zig");
const Buffer = @import("buffer.zig");

const log = std.log.scoped(.kmain);

var started = std.atomic.Value(bool).init(false);

pub fn kmain() void {
    if (Cpu.getCurrent() == 0) {
        console.init();
        log.info("xv6 kernel is booting", .{});
        Kalloc.kinit(); // set up allocator (zig)
        memory.kernelMemoryInit(); // create kernel page table
        memory.kernelMemoryHartInit(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.init(); // set up interrupt controller
        plic.initHart(); // ask PLIC for device interrupts
        Buffer.cache.init_array(); // buffer cache
        c.iinit(); // inode table
        c.fileinit(); // file table
        virtio.init(); // emulated hard disk
        Process.initFirstUser(); // first user process
        started.store(true, .seq_cst);
    } else {
        while (!started.load(.seq_cst)) {}

        log.info("hart {d} starting", .{c.cpuid()});
        memory.kernelMemoryHartInit(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.initHart(); // ask PLIC for device interrupts
    }
    scheduler.schedulerLoop();
}

// overrides the root page allocator
pub const os = struct {
    heap: struct {
        page_allocator: std.mem.Allocator = Kalloc.page_allocator,
    },
};
