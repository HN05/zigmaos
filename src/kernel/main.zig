const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
});
const std = @import("std");
const log_root = @import("klog.zig");
const riscv = @import("common").riscv;
const Kalloc = @import("kalloc.zig");
const plic = @import("plic.zig");
const console = @import("console.zig");
const trap = @import("trap.zig");

const log = std.log.scoped(.kmain);

var started = std.atomic.Value(bool).init(false);

pub fn kmain() void {
    if (c.cpuid() == 0) {
        console.init();
        log.info("xv6 kernel is booting", .{});
        Kalloc.kinit(); // set up allocator (zig)
        c.kvminit(); // create kernel page table
        c.kvminithart(); // turn on paging
        c.procinit(); // process table
        trap.init(); // trap vectors
        trap.initHart(); // install kernel trap vector
        plic.init(); // set up interrupt controller
        plic.initHart(); // ask PLIC for device interrupts
        c.binit(); // buffer cache
        c.iinit(); // inode table
        c.fileinit(); // file table
        c.virtio_disk_init(); // emulated hard disk
        c.userinit(); // first user process
        started.store(true, .seq_cst);
    } else {
        while (!started.load(.seq_cst)) {}

        log.info("hart {d} starting", .{c.cpuid()});
        c.kvminithart(); // turn on paging
        trap.initHart(); // install kernel trap vector
        plic.initHart(); // ask PLIC for device interrupts
    }
    c.scheduler();
}

// overrides the root page allocator
pub const os = struct {
    heap: struct {
        page_allocator: std.mem.Allocator = Kalloc.page_allocator,
    },
};
